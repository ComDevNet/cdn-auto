#!/bin/bash
# cdn-auto configuration v5: repo-local config + AWS preflight + discovery + live test
set -euo pipefail

# --- Locate project root ---
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/automation.conf"
mkdir -p "$CONFIG_DIR"

# --- Detect service user (for owning the config & running AWS commands) ---
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

fatal_exit() {
  local msg="$1"
  if have_whiptail; then
    whiptail --title "Configuration aborted" --msgbox "$msg" 12 74 || true
  else
    echo "ABORT: $msg"
  fi
  exit 2
}

confirm() {
  local msg="$1"
  if have_whiptail; then
    whiptail --yesno "$msg" 10 74
    return $?
  else
    read -rp "$msg [y/N]: " yn
    [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
  fi
}

prompt_text() {
  local title="$1" default="$2" outvar="$3"
  local val
  if have_whiptail; then
    val="$(whiptail --inputbox "$title" 10 74 "$default" 3>&1 1>&2 2>&3 || true)"
  else
    read -rp "$title [$default]: " val
    val="${val:-$default}"
  fi
  printf -v "$outvar" '%s' "$val"
}

menu_select() {
  # Non-cancelable generic menu (used elsewhere)
  if have_whiptail; then
    whiptail --nocancel --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" )
    local n=$(( ${#options[@]} / 2 ))
    echo "$title"
    for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done
    local c; while :; do read -rp "Choose [1-$n]: " c
      if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )); then echo "${options[$(((c-1)*2))]}"; return 0; fi
      echo "Invalid choice."
    done
  fi
}

menu_select_cancelable() {
  # Cancelable menu with Exit button. Returns chosen tag; exits if canceled.
  # usage: menu_select_cancelable "Title" height width menuheight options...
  if have_whiptail; then
    local choice
    choice="$(whiptail --cancel-button "Exit" --ok-button "Select" --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3)" || fatal_exit "User exited at selection: $1"
    echo "$choice"
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" ); local n=$(( ${#options[@]} / 2 ))
    echo "$title"
    for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done
    echo " x) Exit"
    local c
    while :; do
      read -rp "Choose [1-$n or x to exit]: " c
      if [[ "$c" == "x" || "$c" == "X" ]]; then fatal_exit "User exited at selection: $title"; fi
      if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )); then echo "${options[$(((c-1)*2))]}"; return 0; fi
      echo "Invalid choice."
    done
  fi
}

# --- Validation helpers ---
validate_device_location() { [[ "$1" =~ ^[A-Za-z0-9_-]{2,64}$ ]]; }
validate_bucket_url() { [[ "$1" =~ ^s3://[a-z0-9\.\-]{3,63}(/.*)?$ ]]; }
sanitize_subfolder() { local sf="${1#/}"; sf="${sf%/}"; echo "$sf"; }

# --- AWS helpers (execute as SERVICE_USER) ---
aws_as_service_user() {
  if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then
    sudo -u "$SERVICE_USER" env AWS_PROFILE="${AWS_PROFILE:-}" AWS_DEFAULT_REGION="${AWS_REGION:-}" aws "$@"
  else
    env AWS_PROFILE="${AWS_PROFILE:-}" AWS_DEFAULT_REGION="${AWS_REGION:-}" aws "$@"
  fi
}

aws_capture() { aws_as_service_user "$@" 2>/dev/null; }

# --- Preflight checks ---
check_network() {
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  if have_curl; then timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || return 1; fi
  return 0
}

check_aws_identity() {
  if ! have_aws; then say "❌ AWS CLI not installed."; return 2; fi
  if ! aws_as_service_user sts get-caller-identity --output text >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

ensure_preflight_ok() {
  local net_ok=0 id_ok=0
  if check_network; then net_ok=1; else net_ok=0; fi
  if check_aws_identity; then id_ok=1; else id_ok=0; fi

  if (( net_ok==1 && id_ok==1 )); then
    say "✅ Network + AWS identity OK for user '$SERVICE_USER'."
    return 0
  fi

  local msg=""
  if (( net_ok==0 )); then msg+="• Network to s3.amazonaws.com unreachable.\n"; fi
  if (( id_ok==0 )); then msg+="• AWS credentials not available/valid for user '$SERVICE_USER'.\n"; fi
  msg+="\nChoose **Exit** to stop configuration now, or **Continue** for manual entry."
  if have_whiptail; then
    if whiptail --title "Preflight checks failed" --yes-button "Exit" --no-button "Continue" --yesno "$msg" 14 74; then
      fatal_exit "Preflight failed; user chose Exit."
    fi
  else
    echo -e "Preflight checks failed:\n$msg"
    read -rp "Exit now? [Y/n]: " yn; [[ "${yn,,}" != "n" ]] && fatal_exit "Preflight failed; user chose Exit."
  fi

  # Optional: guide aws configure
  if (( id_ok==0 )) && confirm "Run 'aws configure' for user '$SERVICE_USER' now?"; then
    if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then
      sudo -u "$SERVICE_USER" aws configure || true
    else
      aws configure || true
    fi
  fi
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

# Run preflight so discovery won't be silently empty
ensure_preflight_ok || true

# Try to infer default region
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

# 4) Region (optional)
prompt_text "AWS region (optional, e.g., us-east-1)" "${AWS_REGION}" AWS_REGION

# 5) Bucket discovery with EXIT on error
pick_bucket() {
  local out rc err="" buckets=() opts=()

  if have_aws && check_network; then
    out="$(aws_as_service_user s3 ls 2>&1)"; rc=$?
    if (( rc != 0 )); then err="$out"; out=""
    fi
  else
    err="Network or AWS CLI unavailable."
    out=""
  fi

  if [[ -z "$out" ]]; then
    local msg="Could not discover S3 buckets for user '$SERVICE_USER'.\n\nError:\n${err:-<no details>}\n\nSelect **Exit** to stop now, or **Manual** to type a bucket URL."
    if have_whiptail; then
      if whiptail --title "Bucket discovery failed" --yes-button "Exit" --no-button "Manual" --yesno "$msg" 18 74; then
        fatal_exit "User exited at bucket discovery."
      fi
    else
      echo -e "$msg"
      read -rp "Exit? [Y/n]: " yn; [[ "${yn,,}" != "n" ]] && fatal_exit "User exited at bucket discovery."
    fi
    # Manual entry
    while :; do
      prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
      S3_BUCKET="${S3_BUCKET%/}"
      validate_bucket_url "$S3_BUCKET" && break || say "Bucket must start with s3://"
    done
    return 0
  fi

  # Build discovered menu
  while IFS= read -r line; do
    local b="$(echo "$line" | awk '{print $3}')"
    [[ -n "$b" ]] && opts+=( "$b" "$b" )
  done <<< "$out"
  opts+=( "CUSTOM" "Enter bucket manually" )

  local choice
  choice="$(menu_select_cancelable "Select S3 bucket (discovered via AWS CLI)" 20 74 12 "${opts[@]}")"
  if [[ "$choice" == "CUSTOM" ]]; then
    while :; do
      prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
      S3_BUCKET="${S3_BUCKET%/}"
      validate_bucket_url "$S3_BUCKET" && break || say "Bucket must start with s3://"
    done
  else
    S3_BUCKET="s3://$choice"
  fi
}
pick_bucket

# 6) Subfolder discovery (with Exit on AccessDenied-like errors)
pick_subfolder() {
  local bucket_name="${S3_BUCKET#s3://}"
  bucket_name="${bucket_name%%/*}"
  local out rc err="" subs=() opts=()

  if have_aws && check_network; then
    out="$(aws_as_service_user s3 ls "s3://$bucket_name/" 2>&1)"; rc=$?
    if (( rc != 0 )); then err="$out"; out=""
    fi
  else
    err="Network or AWS CLI unavailable."; out=""
  fi

  opts+=( "NONE" "<bucket root>" )
  if [[ -n "$out" ]]; then
    while IFS= read -r line; do
      if [[ "$line" == PRE* ]]; then
        subs+=( "$(echo "$line" | awk '{print $2}' | sed 's:/$::')" )
      fi
    done <<< "$out"
    for s in "${subs[@]}"; do opts+=( "$s" "$s" ); done
  else
    if [[ -n "$err" ]]; then
      local msg="Could not list top-level prefixes in s3://$bucket_name/.\n\nError:\n${err:-<no details>}\n\nSelect **Exit** to stop now, or **Manual** to type a subfolder."
      if have_whiptail; then
        if whiptail --title "Subfolder discovery failed" --yes-button "Exit" --no-button "Manual" --yesno "$msg" 18 74; then
          fatal_exit "User exited at subfolder discovery."
        fi
      else
        echo -e "$msg"
        read -rp "Exit? [Y/n]: " yn; [[ "${yn,,}" != "n" ]] && fatal_exit "User exited at subfolder discovery."
      fi
    fi
    opts+=( "CUSTOM" "Enter subfolder manually" )
  fi

  local choice
  choice="$(menu_select_cancelable "Select S3 subfolder in s3://$bucket_name/" 20 74 12 "${opts[@]}")"
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
if ! confirm "Save configuration?"; then fatal_exit "User canceled at confirmation."; fi

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

# --- Live test upload ---
test_upload() {
  if ! have_aws; then say "❌ AWS CLI not installed."; return 1; fi
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
  local s3url="${S3_BUCKET%/}"; [[ -n "$S3_SUBFOLDER" ]] && s3url="${s3url}/${S3_SUBFOLDER}"
  local key_path="RACHEL/_config_test_${tsf}.txt"
  local full="${s3url}/${key_path}"
  local bucket_name="${S3_BUCKET#s3://}"; bucket_name="${bucket_name%%/*}"
  local key_key=""; [[ -n "$S3_SUBFOLDER" ]] && key_key="${S3_SUBFOLDER}/${key_path}" || key_key="${key_path}"
  [[ -n "$AWS_REGION" ]] && export AWS_DEFAULT_REGION="$AWS_REGION"
  [[ -n "$AWS_PROFILE" ]] && export AWS_PROFILE
  say "▶ Uploading test object to: $full"
  if ! aws_as_service_user s3 cp "$tmpfile" "$full" >/dev/null 2>&1; then
    say "❌ Upload failed (PutObject)."; rm -f "$tmpfile"; return 1
  fi
  rm -f "$tmpfile"
  if aws_as_service_user s3api head-object --bucket "$bucket_name" --key "$key_key" >/dev/null 2>&1; then
    say "✅ Test upload verified with head-object."
  else
    say "⚠️ Upload succeeded, but verification (GetObject) failed. This may be expected if policy denies GetObject."
  fi
  return 0
}

attempt=1; max_attempts=3
until test_upload; do
  say "Configuration test failed ($attempt/$max_attempts)."
  if (( attempt >= max_attempts )); then
    fatal_exit "Giving up after $max_attempts attempts. Please fix AWS/network and re-run configure."
  fi
  if confirm "Open 'aws configure' for '$SERVICE_USER' now?"; then
    if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then sudo -u "$SERVICE_USER" aws configure || true
    else aws configure || true; fi
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
