#!/bin/bash
# cdn-auto: interactive configuration kept INSIDE the repo + S3 discovery + live test
set -euo pipefail

# --- Locate project root ---
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/automation.conf"
mkdir -p "$CONFIG_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }

# --- Cosmetic fallback for lolcat/figlet if caller sources this ---
if ! command -v lolcat >/dev/null 2>&1; then lolcat() { cat; }; fi
if ! command -v figlet >/dev/null 2>&1; then figlet() { cat; }; fi

# --- Load existing config if present ---
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# Defaults
SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"       # v2 only: oc4d | cape_coast_d
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-default}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"

# --- UI helpers ---
have_whiptail() { command -v whiptail >/dev/null 2>&1; }

confirm() {
  local msg="$1"
  if have_whiptail; then
    whiptail --yesno "$msg" 10 70
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
    val="$(whiptail --inputbox "$title" 10 72 "$default" 3>&1 1>&2 2>&3 || true)"
  else
    read -rp "$title [$default]: " val
    val="${val:-$default}"
  fi
  printf -v "$outvar" '%s' "$val"
}

menu_select() {
  # usage: menu_select "Title" height width menuheight options...
  if have_whiptail; then
    whiptail --nocancel --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" )
    echo "$title"
    local i=0; local n=$(( ${#options[@]} / 2 ))
    while (( i < ${#options[@]} )); do
      local tag="${options[i]}"; local label="${options[i+1]}"
      printf "  %2d) %s\n" "$((i/2+1))" "$label"
      i=$((i+2))
    done
    local choice
    while :; do
      read -rp "Choose [1-$n]: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<= n )); then
        echo "${options[$(( (choice-1)*2 ))]}"
        return 0
      fi
      echo "Invalid choice."
    done
  fi
}

# --- Validation ---
validate_device_location() { [[ "$1" =~ ^[A-Za-z0-9_-]{2,64}$ ]]; }
validate_bucket() { [[ "$1" =~ ^s3://[a-z0-9\.\-]{3,63}([/].*)?$ ]]; }
sanitize_subfolder() {
  local sf="${1#/}"; sf="${sf%/}"; echo "$sf"
}

# --- AWS helpers ---
have_aws() { command -v aws >/dev/null 2>&1; }

# Execute AWS cmd; try as current user, then as SUDO_USER (so creds work even under sudo)
aws_run() {
  if aws "$@"; then return 0; fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "$USER" ]]; then
    sudo -u "$SUDO_USER" aws "$@"
    return $?
  fi
  return 1
}

aws_capture() {
  local out
  if out="$(aws "$@" 2>/dev/null)"; then
    printf '%s' "$out"; return 0
  fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "$USER" ]]; then
    if out="$(sudo -u "$SUDO_USER" aws "$@" 2>/dev/null)"; then
      printf '%s' "$out"; return 0
    fi
  fi
  return 1
}

list_buckets() {
  # Returns bucket names (no s3:// prefix), one per line. Uses `aws s3 ls`.
  aws_capture s3 ls | awk '{print $3}'
}

list_subfolders_top() {
  local bucket="$1"
  # Prefer aws s3 ls which prints "PRE folder/"
  aws_capture s3 ls "s3://$bucket/" | awk '/^ *PRE /{print $2}' | sed 's:/$::'
}

pick_bucket() {
  local buckets_text="" buckets=() opts=()
  if have_aws && buckets_text="$(list_buckets)"; then
    mapfile -t buckets <<<"$buckets_text"
  fi
  # Build menu: CUSTOM + up to top 50 buckets
  opts+=( "CUSTOM" "Enter bucket manually" )
  local count=0
  for b in "${buckets[@]}"; do
    [[ -n "$b" ]] || continue
    opts+=( "$b" "$b" )
    count=$((count+1))
    (( count >= 50 )) && break
  done
  local choice
  if (( ${#opts[@]} > 2 )); then
    choice="$(menu_select "Select S3 bucket (discovered via AWS CLI)" 20 72 12 "${opts[@]}")"
    if [[ "$choice" == "CUSTOM" ]]; then
      while :; do
        prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
        S3_BUCKET="${S3_BUCKET%/}"
        if validate_bucket "$S3_BUCKET"; then break; else say "Bucket must start with s3://"; fi
      done
    else
      S3_BUCKET="s3://$choice"
    fi
  else
    # No discovery available; manual
    while :; do
      prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
      S3_BUCKET="${S3_BUCKET%/}"
      if validate_bucket "$S3_BUCKET"; then break; else say "Bucket must start with s3://"; fi
    done
  fi
}

pick_subfolder() {
  local bucket_name="${S3_BUCKET#s3://}"
  local subs_text="" subs=() opts=()
  if have_aws && subs_text="$(list_subfolders_top "$bucket_name")"; then
    mapfile -t subs <<<"$subs_text"
  fi

  opts+=( "NONE" "<bucket root>" )
  opts+=( "CUSTOM" "Enter subfolder manually" )
  local count=0
  for s in "${subs[@]}"; do
    [[ -n "$s" ]] || continue
    opts+=( "$s" "$s" )
    count=$((count+1))
    (( count >= 50 )) && break
  done

  local choice
  choice="$(menu_select "Select S3 subfolder in s3://$bucket_name/ (top-level prefixes)" 20 72 12 "${opts[@]}")"
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

# --- Gather inputs ---

# 1) Server version
sel=$(menu_select "Select server version" 15 72 5 \
  v4 "Server v4 (Apache / access.log*)" \
  v5 "Server v5 (OC4D or Cape Coast Castle)" \
)
if [[ "$sel" == "v4" ]]; then SERVER_VERSION="v1"; else SERVER_VERSION="v2"; fi

# 2) If v2, select processor flavor
if [[ "$SERVER_VERSION" == "v2" ]]; then
  PYTHON_SCRIPT=$(menu_select "Select logs flavor (v2)" 12 72 5 \
    oc4d "OC4D logs (logv2.py)" \
    cape_coast_d "Cape Coast Castle logs (castle.py)" \
  )
else
  PYTHON_SCRIPT="oc4d"
fi

# 3) Device location (used in folder and CSV name)
while :; do
  prompt_text "Device location (letters/numbers/_/-)" "${DEVICE_LOCATION}" DEVICE_LOCATION
  if validate_device_location "$DEVICE_LOCATION"; then break; else
    say "Invalid location. Use 2-64 chars: letters, digits, '_' or '-'."
  fi
done

# 4) S3 bucket (discover + select with fallback)
pick_bucket

# 5) S3 subfolder (discover + select with fallback)
pick_subfolder
S3_SUBFOLDER="$(sanitize_subfolder "$S3_SUBFOLDER")"

# 6) Schedule
sched=$(menu_select "Choose schedule" 15 72 7 \
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
      if [[ "$RUN_INTERVAL" =~ ^[0-9]+$ ]] && (( RUN_INTERVAL >= 300 )); then
        SCHEDULE_TYPE="custom"; break
      else say "Enter a number >= 300."; fi
    done
    ;;
esac

# --- Show summary ---
summary=$(cat <<EOF
Server version : $SERVER_VERSION
Logs flavor    : $PYTHON_SCRIPT
Device location: $DEVICE_LOCATION
S3 bucket      : $S3_BUCKET
S3 subfolder   : ${S3_SUBFOLDER:-<root>}
Schedule       : $SCHEDULE_TYPE (interval=${RUN_INTERVAL}s)
Config file    : $CONFIG_FILE
EOF
)
if have_whiptail; then whiptail --title "Confirm configuration" --msgbox "$summary" 18 74; else echo; echo "$summary"; echo; fi

if ! confirm "Save configuration?"; then
  say "Aborted."
  exit 1
fi

# --- Save config atomically inside repo ---
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
EOF
mv -f "$tmp" "$CONFIG_FILE"
say "✅ Saved: $CONFIG_FILE"

# --- Post-config verification: live test upload ---
test_upload() {
  if ! have_aws; then
    say "❌ AWS CLI not installed. Install: sudo apt-get install -y awscli (or AWS CLI v2)"
    return 1
  fi

  # Quick bucket reachability
  if ! aws_run s3 ls "$S3_BUCKET" >/dev/null 2>&1; then
    say "❌ Cannot list $S3_BUCKET. Check credentials, region, or permissions."
    return 1
  fi

  local tsf="$(date +%Y%m%d_%H%M%S)"
  local tmpfile
  tmpfile="$(mktemp /tmp/cdn_auto_cfgtest.XXXXXX)"
  cat > "$tmpfile" <<EOD
cdn-auto configuration test
timestamp: $tsf
project_root: $PROJECT_ROOT
server_version: $SERVER_VERSION
logs_flavor: $PYTHON_SCRIPT
device_location: $DEVICE_LOCATION
s3_bucket: $S3_BUCKET
s3_subfolder: ${S3_SUBFOLDER:-<root>}
EOD

  # Compose remote path: <bucket>/<subfolder>/RACHEL/_config_test_<ts>.txt
  local base="${S3_BUCKET%/}"
  if [[ -n "$S3_SUBFOLDER" ]]; then base="${base}/${S3_SUBFOLDER}"; fi
  local key="${base}/RACHEL/_config_test_${tsf}.txt"

  say "▶ Uploading test object to: $key"
  if ! aws_run s3 cp "$tmpfile" "$key" >/dev/null 2>&1; then
    say "❌ Upload failed."
    rm -f "$tmpfile"
    return 1
  fi
  rm -f "$tmpfile"

  # Verify it exists
  if aws_run s3 ls "$key" >/dev/null 2>&1; then
    say "✅ Test upload verified at: $key"
    return 0
  else
    say "⚠️ Upload seemed to work, but verification failed."
    return 1
  fi
}

attempt=1
max_attempts=3
until test_upload; do
  say "Configuration test failed ($attempt/$max_attempts)."
  if (( attempt >= max_attempts )); then
    say "❌ Giving up after $max_attempts attempts. Re-run configure to try again."
    exit 2
  fi
  if confirm "Fix S3 settings now?"; then
    pick_bucket
    pick_subfolder
    S3_SUBFOLDER="$(sanitize_subfolder "$S3_SUBFOLDER")"
    # Save new S3 settings immediately before retry, to keep config consistent
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
EOF
    mv -f "$tmp" "$CONFIG_FILE"
    say "💾 Updated S3 settings saved to: $CONFIG_FILE"
  else
    say "You can re-run this script later to adjust settings."
    exit 2
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
