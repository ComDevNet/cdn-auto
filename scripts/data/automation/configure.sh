#!/bin/bash
# cdn-auto configuration: repo-local config + AWS preflight + discovery + live test
set -euo pipefail

# --- Locate project root ---
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/automation.conf"
mkdir -p "$CONFIG_DIR"

# --- Find service user from the installed unit (fallback to pi or SUDO_USER) ---
SERVICE_UNIT="/etc/systemd/system/v5-log-processor.service"
SERVICE_USER="$(awk -F= '/^User=/{print $2}' "$SERVICE_UNIT" 2>/dev/null | tail -n1)"
if [[ -z "${SERVICE_USER:-}" ]]; then
  SERVICE_USER="${SUDO_USER:-pi}"
fi
SERVICE_GROUP="$SERVICE_USER"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }

have_whiptail() { command -v whiptail >/dev/null 2>&1; }
have_curl() { command -v curl >/dev/null 2>&1; }
have_aws() { command -v aws >/dev/null 2>&1; }

confirm() {
  local msg="$1"
  if have_whiptail; then whiptail --yesno "$msg" 10 74; else
    read -rp "$msg [y/N]: " yn; [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
  fi
}

prompt_text() {
  local title="$1" default="$2" outvar="$3"
  local val
  if have_whiptail; then
    val="$(whiptail --inputbox "$title" 10 74 "$default" 3>&1 1>&2 2>&3 || true)"
  else
    read -rp "$title [$default]: " val; val="${val:-$default}"
  fi
  printf -v "$outvar" '%s' "$val"
}

menu_select() {
  if have_whiptail; then
    whiptail --nocancel --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" ); local n=$(( ${#options[@]} / 2 ))
    echo "$title"
    for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done
    local c; while :; do read -rp "Choose [1-$n]: " c
      if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )); then echo "${options[$(((c-1)*2))]}"; return 0; fi
      echo "Invalid choice."
    done
  fi
}

# --- Validation helpers ---
validate_device_location() { [[ "$1" =~ ^[A-Za-z0-9_-]{2,64}$ ]]; }
validate_bucket_url() { [[ "$1" =~ ^s3://[a-z0-9\.\-]{3,63}(/.*)?$ ]]; }
sanitize_subfolder() { local sf="${1#/}"; sf="${sf%/}"; echo "$sf"; }

# --- AWS helpers (execute as SERVICE_USER when possible) ---
aws_as_service_user() {
  # Use existing env AWS_PROFILE/AWS_REGION if set in shell; pass through to sudo env
  if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then
    sudo -u "$SERVICE_USER" env AWS_PROFILE="${AWS_PROFILE:-}" AWS_DEFAULT_REGION="${AWS_REGION:-}" aws "$@"
  else
    env AWS_PROFILE="${AWS_PROFILE:-}" AWS_DEFAULT_REGION="${AWS_REGION:-}" aws "$@"
  fi
}
aws_capture() {
  local out
  if out="$(aws_as_service_user "$@" 2>/dev/null)"; then printf '%s' "$out"; return 0; fi
  return 1
}

# --- Preflight checks ---
check_network() {
  # DNS + HTTPS to S3 public endpoint
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  if have_curl; then
    timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || return 1
  fi
  return 0
}

check_aws_identity() {
  if ! have_aws; then
    say "❌ AWS CLI not installed."
    return 2
  fi
  local id rc=0
  if ! id="$(aws_as_service_user sts get-caller-identity --output text 2>&1)"; then
    say "❌ AWS identity check failed for user '$SERVICE_USER'. Error:"
    echo "$id"
    rc=1
  else
    say "✅ AWS identity (user '$SERVICE_USER'): $id"
    rc=0
  fi
  return $rc
}

ensure_preflight_ok() {
  if ! check_network; then
    if have_whiptail; then whiptail --title "Network check" --msgbox "Cannot reach s3.amazonaws.com over HTTPS.\nCheck internet or DNS and try again." 12 74; fi
    say "❌ Network unreachable (s3.amazonaws.com)."
    return 1
  fi
  local rc=0
  if ! check_aws_identity; then
    if confirm "Run 'aws configure' for user '$SERVICE_USER' now?"; then
      if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then
        sudo -u "$SERVICE_USER" aws configure || true
      else
        aws configure || true
      fi
      # re-check identity
      check_aws_identity || rc=1
    else
      rc=1
    fi
  fi
  return $rc
}

# --- Load existing config if present ---
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE" || true
fi

# Defaults
SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-}"

# --- Start with preflight so bucket discovery isn't blank ---
if ! ensure_preflight_ok; then
  say "Proceeding, but S3 discovery may be empty until AWS/network are fixed."
fi

# Optional: discover default region
if [[ -z "$AWS_REGION" && $(have_aws && echo yes) == "yes" ]]; then
  AWS_REGION="$(aws_capture configure get region || true)"
fi

# --- Guided prompts ---

# 1) Server version
sel=$(menu_select "Select server version" 15 74 5 \
  v4 "Server v4 (Apache / access.log*)" \
  v5 "Server v5 (OC4D or Cape Coast Castle)" \
)
if [[ "$sel" == "v4" ]]; then SERVER_VERSION="v1"; else SERVER_VERSION="v2"; fi

# 2) If v2, select processor flavor
if [[ "$SERVER_VERSION" == "v2" ]]; then
  PYTHON_SCRIPT=$(menu_select "Select logs flavor (v2)" 12 74 5 \
    oc4d "OC4D logs (logv2.py)" \
    cape_coast_d "Cape Coast Castle logs (castle.py)" \
  )
else
  PYTHON_SCRIPT="oc4d"
fi

# 3) Device location
while :; do
  prompt_text "Device location (letters/numbers/_/-)" "${DEVICE_LOCATION}" DEVICE_LOCATION
  validate_device_location "$DEVICE_LOCATION" && break
  say "Invalid location. Use 2-64 chars: [A-Za-z0-9_-]"
done

# 4) AWS region (optional; helps avoid redirects)
prompt_text "AWS region (optional, e.g., us-east-1)" "${AWS_REGION}" AWS_REGION

# 5) S3 bucket discovery
pick_bucket() {
  local buckets_text="" buckets=() opts=()
  if have_aws && check_network; then
    buckets_text="$(aws_capture s3 ls || true)"
  else
    buckets_text=""
  fi
  mapfile -t buckets <<<"$buckets_text"
  opts+=( "CUSTOM" "Enter bucket manually" )
  local added=0
  for bline in "${buckets[@]}"; do
    # expect "2025-.. ..:..:.. bucket-name"
    local b="$(echo "$bline" | awk '{print $3}')"
    [[ -n "$b" ]] || continue
    opts+=( "$b" "$b" )
    added=$((added+1))
    (( added>=50 )) && break
  done
  local choice
  if (( ${#opts[@]} > 2 )); then
    choice="$(menu_select "Select S3 bucket (discovered via AWS CLI for user '$SERVICE_USER')" 20 74 12 "${opts[@]}")"
    if [[ "$choice" == "CUSTOM" ]]; then
      while :; do
        prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
        S3_BUCKET="${S3_BUCKET%/}"
        validate_bucket_url "$S3_BUCKET" && break || say "Bucket must start with s3://"
      done
    else
      S3_BUCKET="s3://$choice"
    fi
  else
    # fall back to manual
    while :; do
      prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
      S3_BUCKET="${S3_BUCKET%/}"
      validate_bucket_url "$S3_BUCKET" && break || say "Bucket must start with s3://"
    done
  fi
}
pick_bucket

# 6) Subfolder discovery (top-level prefixes)
pick_subfolder() {
  local bucket_name="${S3_BUCKET#s3://}"
  local subs_text="" subs=() opts=()
  if have_aws && check_network; then
    subs_text="$(aws_capture s3 ls "s3://$bucket_name/" || true)"
  fi
  # Parse "PRE folder/"
  while IFS= read -r line; do
    if [[ "$line" == PRE* ]]; then
      subs+=( "$(echo "$line" | awk '{print $2}' | sed 's:/$::')" )
    fi
  done <<< "$subs_text"
  opts+=( "NONE" "<bucket root>" "CUSTOM" "Enter subfolder manually" )
  local added=0
  for s in "${subs[@]}"; do
    [[ -n "$s" ]] || continue
    opts+=( "$s" "$s" ); added=$((added+1)); (( added>=100 )) && break
  done
  local choice
  choice="$(menu_select "Select S3 subfolder in s3://$bucket_name/ (if AccessDenied appears, choose CUSTOM)" 20 74 12 "${opts[@]}")"
  case "$choice" in
    NONE) S3_SUBFOLDER="" ;;
    CUSTOM)
      prompt_text "Subfolder (no leading slash; empty for root)" "${S3_SUBFOLDER}" S3_SUBFOLDER
      S3_SUBFOLDER="$(sanitize_subfolder "$S3_SUBFOLDER")"
      ;;
    *)
      S3_SUBFOLDER="$choice"
      ;;
  esac
}
pick_subfolder

# 7) Schedule
sched=$(menu_select "Choose schedule" 15 74 7 \
  hourly "Every hour" \
  daily  "Once per day" \
  weekly "Once per week" \
  custom "Custom interval (seconds)" \
)
case "$sched" in
  hourly) SCHEDULE_TYPE="hourly"; RUN_INTERVAL="3600" ;;
  daily)  SCHEDULE_TYPE="daily";  RUN_INTERVAL="86400" ;;
  weekly) SCHEDULE_TYPE="weekly"; RUN_INTERVAL="604800" ;;
  custom)
    while :; do
      prompt_text "Custom interval in seconds (>=300)" "${RUN_INTERVAL}" RUN_INTERVAL
      [[ "$RUN_INTERVAL" =~ ^[0-9]+$ ]] && (( RUN_INTERVAL >= 300 )) && break
      say "Enter a number >= 300."
    done
    ;;
esac

# --- Summary ---
summary=$(cat <<EOF
Service user   : $SERVICE_USER
Server version : $SERVER_VERSION
Logs flavor    : $PYTHON_SCRIPT
Device location: $DEVICE_LOCATION
AWS region     : ${AWS_REGION:-<none>}
S3 bucket      : $S3_BUCKET
S3 subfolder   : ${S3_SUBFOLDER:-<root>}
Schedule       : $SCHEDULE_TYPE (interval=${RUN_INTERVAL}s)
Config file    : $CONFIG_FILE
EOF
)
if have_whiptail; then whiptail --title "Confirm configuration" --msgbox "$summary" 19 74; else echo; echo "$summary"; echo; fi
if ! confirm "Save configuration?"; then say "Aborted."; exit 1; fi

# --- Save config and set ownership to service user ---
umask 077
tmp="${CONFIG_FILE}.tmp"
cat > "$tmp" <<EOF
# cdn-auto automation config (kept INSIDE the repo)
SERVER_VERSION="$SERVER_VERSION"
DEVICE_LOCATION="$DEVICE_LOCATION"
PYTHON_SCRIPT="$PYTHON_SCRIPT"
S3_BUCKET="$S3_BUCKET"
S3_SUBFOLDER="$S3_SUBFOLDER"
SCHEDULE_TYPE="$SCHEDULE_TYPE"
RUN_INTERVAL="$RUN_INTERVAL"
AWS_PROFILE="${AWS_PROFILE}"
AWS_REGION="${AWS_REGION}"
EOF
mv -f "$tmp" "$CONFIG_FILE"
sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "$CONFIG_FILE"
sudo chmod 600 "$CONFIG_FILE"
say "💾 Saved: $CONFIG_FILE (owner: $SERVICE_USER)"

# --- Live test upload (no ListBucket required) ---
test_upload() {
  if ! have_aws; then
    say "❌ AWS CLI not installed."; return 1
  fi
  # Build test file
  local tsf="$(date +%Y%m%d_%H%M%S)"
  local tmpfile; tmpfile="$(mktemp /tmp/cdn_auto_cfgtest.XXXXXX)"
  cat > "$tmpfile" <<EOD
cdn-auto configuration test
timestamp: $tsf
server_version: $SERVER_VERSION
logs_flavor: $PYTHON_SCRIPT
device_location: $DEVICE_LOCATION
bucket: $S3_BUCKET
subfolder: ${S3_SUBFOLDER:-<root>}
EOD

  # Compose S3 URL and also bucket/key for head-object
  local s3url="${S3_BUCKET%/}"
  [[ -n "$S3_SUBFOLDER" ]] && s3url="${s3url}/${S3_SUBFOLDER}"
  local key_path="RACHEL/_config_test_${tsf}.txt"
  local full="${s3url}/${key_path}"
  local bucket_name="${S3_BUCKET#s3://}"; bucket_name="${bucket_name%%/*}"
  local key_key=""
  if [[ -n "$S3_SUBFOLDER" ]]; then key_key="${S3_SUBFOLDER}/${key_path}"; else key_key="${key_path}"; fi

  [[ -n "$AWS_REGION" ]] && export AWS_DEFAULT_REGION="$AWS_REGION"
  [[ -n "$AWS_PROFILE" ]] && export AWS_PROFILE

  say "▶ Uploading test object to: $full"
  if ! aws_as_service_user s3 cp "$tmpfile" "$full" >/dev/null 2>&1; then
    say "❌ Upload failed (PutObject). Check permissions/region/endpoint."
    rm -f "$tmpfile"; return 1
  fi
  rm -f "$tmpfile"

  # Try to verify with head-object (GetObject). If denied, still accept the upload.
  local head_rc=0
  if ! aws_as_service_user s3api head-object --bucket "$bucket_name" --key "$key_key" >/dev/null 2>&1; then
    say "⚠️ Verification via head-object failed. This may be OK if the role has PutObject but no GetObject."
    head_rc=1
  else
    say "✅ Test upload verified with head-object."
  fi
  return 0
}

attempt=1; max_attempts=3
until test_upload; do
  say "Configuration test failed ($attempt/$max_attempts)."
  if (( attempt >= max_attempts )); then
    say "❌ Giving up after $max_attempts attempts. Re-run configure after fixing AWS/network."
    exit 2
  fi
  if confirm "Open AWS reconfiguration (aws configure) for '$SERVICE_USER' now?"; then
    if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then
      sudo -u "$SERVICE_USER" aws configure || true
    else
      aws configure || true
    fi
  fi
  attempt=$((attempt+1))
done

# --- Timer enable/update AFTER successful test ---
SERVICE="v5-log-processor.service"
TIMER="v5-log-processor.timer"
DROP_DIR="/etc/systemd/system/${TIMER}.d"
OVERRIDE="${DROP_DIR}/override.conf"

sudo mkdir -p "$DROP_DIR"
{
  echo "[Timer]"
  echo "OnCalendar="
  echo "OnUnitActiveSec="
  case "$SCHEDULE_TYPE" in
    hourly) echo "OnCalendar=hourly" ;;
    daily)  echo "OnCalendar=daily"  ;;
    weekly) echo "OnCalendar=weekly" ;;
    custom) echo "OnUnitActiveSec=${RUN_INTERVAL}" ;;
  esac
  echo "Persistent=true"
} | sudo tee "$OVERRIDE" >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable "$TIMER" >/dev/null
sudo systemctl restart "$TIMER"
say "⏱  Timer updated and started: $TIMER"

say "✅ Configuration complete."
