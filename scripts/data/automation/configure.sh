#!/bin/bash
# Interactive config (inside repo) with clear menus + validation
set -euo pipefail

# --- Locate project root ---
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/automation.conf"
mkdir -p "$CONFIG_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }

# Load existing config if present
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# Defaults
SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-default}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"

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
    val="$(whiptail --inputbox "$title" 10 70 "$default" 3>&1 1>&2 2>&3 || true)"
  else
    read -rp "$title [$default]: " val
    val="${val:-$default}"
  fi
  printf -v "$outvar" '%s' "$val"
}

menu_select() {
  # args: title height width menuheight options... (pairs: tag item)
  if have_whiptail; then
    whiptail --nocancel --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" )
    echo "$title"
    local i=0
    while (( i < ${#options[@]} )); do
      local tag="${options[i]}"; local label="${options[i+1]}"
      printf "  %s) %s\n" "$((i/2+1))" "$label"
      i=$((i+2))
    done
    local choice
    while :; do
      read -rp "Choose [1-$(( ${#options[@]} / 2 ))]: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<= ${#options[@]} / 2 )); then
        echo "${options[$(( (choice-1)*2 ))]}"
        return 0
      fi
      echo "Invalid choice."
    done
  fi
}

validate_device_location() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{2,64}$ ]]
}

validate_bucket() {
  [[ "$1" =~ ^s3://[a-z0-9\.\-]{3,63}([/].*)?$ ]]
}

# --- Gather inputs ---

# 1) Server version
sel=$(menu_select "Select server version" 15 70 5 \
  v4 "Server v4 (Apache / access.log*)" \
  v5 "Server v5 (OC4D or Cape Coast Castle)" \
  )
if [[ "$sel" == "v4" ]]; then SERVER_VERSION="v1"; else SERVER_VERSION="v2"; fi

# 2) If v2, select processor flavor
if [[ "$SERVER_VERSION" == "v2" ]]; then
  PYTHON_SCRIPT=$(menu_select "Select logs flavor (v2)" 12 70 5 \
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

# 4) S3 bucket (must start with s3://)
while :; do
  prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
  # drop trailing slashes
  S3_BUCKET="${S3_BUCKET%/}"
  if validate_bucket "$S3_BUCKET"; then break; else
    say "Bucket must start with s3:// and look like a valid name."
  fi
done

# 5) S3 subfolder (optional; no leading slash)
prompt_text "S3 subfolder (optional; no leading slash)" "${S3_SUBFOLDER}" S3_SUBFOLDER
S3_SUBFOLDER="${S3_SUBFOLDER#/}"
S3_SUBFOLDER="${S3_SUBFOLDER%/}"

# 6) Schedule
sched=$(menu_select "Choose schedule" 15 70 6 \
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
        SCHEDULE_TYPE="custom"
        break
      else
        say "Enter a number >= 300."
      fi
    done
    ;;
esac

# --- Show summary ---
summary=$(cat <<EOF
Server version : $SERVER_VERSION
Logs flavor    : $PYTHON_SCRIPT
Device location: $DEVICE_LOCATION
S3 bucket      : $S3_BUCKET
S3 subfolder   : ${S3_SUBFOLDER:-<none>}
Schedule       : $SCHEDULE_TYPE (interval=${RUN_INTERVAL}s)
Config file    : $CONFIG_FILE
EOF
)
if have_whiptail; then whiptail --title "Confirm configuration" --msgbox "$summary" 16 72; else echo; echo "$summary"; echo; fi

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

# --- Best-effort timer update (keeps service installed by install.sh) ---
# We write a systemd drop-in to switch schedule without clobbering the unit.
SERVICE="v5-log-processor.service"
TIMER="v5-log-processor.timer"
DROP_DIR="/etc/systemd/system/${TIMER}.d"
OVERRIDE="${DROP_DIR}/override.conf"

sudo mkdir -p "$DROP_DIR"

# Build override text
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
say "⏱  Timer updated: $TIMER"

say "Done."
