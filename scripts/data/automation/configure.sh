#!/bin/bash
# cdn-auto configure (defaults-first; no region flags; SSE fallback; fixed temp-file perms)
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/automation.conf"
mkdir -p "$CONFIG_DIR"

SERVICE_UNIT="/etc/systemd/system/v5-log-processor.service"
SERVICE_USER="$(awk -F= '/^User=/{print $2}' "$SERVICE_UNIT" 2>/dev/null | tail -n1)"
[ -z "${SERVICE_USER:-}" ] && SERVICE_USER="${SUDO_USER:-pi}"
SERVICE_GROUP="$SERVICE_USER"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
say(){ echo "[$(ts)] $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
have_whiptail(){ have whiptail; }

confirm(){
  local msg="$1"
  if have_whiptail; then whiptail --yesno "$msg" 10 74
  else read -rp "$msg [y/N]: " yn; [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
  fi
}

prompt_text(){
  local title="$1" default="$2" outvar="$3" val
  if have_whiptail; then
    val="$(whiptail --inputbox "$title" 10 74 "$default" 3>&1 1>&2 2>&3 || true)"
  else
    read -rp "$title [$default]: " val; val="${val:-$default}"
  fi
  printf -v "$outvar" '%s' "$val"
}

menu_select(){
  if have_whiptail; then
    whiptail --nocancel --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" ); local n=$(( ${#options[@]} / 2 ))
    echo "$title"
    for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done
    local c; while :; do read -rp "Choose [1-$n]: " c; [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )) && { echo "${options[$(((c-1)*2))]}"; return 0; }; echo "Invalid choice."; done
  fi
}

menu_select_cancelable(){
  if have_whiptail; then
    local choice
    choice="$(whiptail --cancel-button "Exit" --ok-button "Select" --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3)" || { echo "__EXIT__"; return 0; }
    echo "$choice"
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" ); local n=$(( ${#options[@]} / 2 ))
    echo "$title"; for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done; echo " x) Exit"
    local c; while :; do read -rp "Choose [1-$n or x]: " c; [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )) && { echo "${options[$(((c-1)*2))]}"; return 0; }; [[ "$c" =~ ^[xX]$ ]] && { echo "__EXIT__"; return 0; }; echo "Invalid choice."; done
  fi
}

validate_device_location(){ [[ "$1" =~ ^[A-Za-z0-9_-]{2,64}$ ]]; }
sanitize_subfolder(){ local sf="${1#/}"; sf="${sf%/}"; echo "$sf"; }

aws_su(){
  if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then sudo -u "$SERVICE_USER" aws "$@"
  else aws "$@"
  fi
}
aws_capture(){ aws_su "$@" 2>/dev/null; }

check_network(){
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  have curl && timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || true
  return 0
}
check_aws_identity(){
  aws_su sts get-caller-identity --output text >/dev/null 2>&1 && { say "✅ AWS identity OK for '$SERVICE_USER'."; return 0; }
  say "⚠️  AWS identity not confirmed for '$SERVICE_USER' (continuing allowed)."; return 1
}
ensure_preflight_ok(){
  local net_ok=0 id_ok=0
  check_network && net_ok=1 || net_ok=0
  check_aws_identity && id_ok=1 || id_ok=0
  (( net_ok==1 && id_ok==1 )) && return 0
  local msg=""
  (( net_ok==0 )) && msg+="• Network to s3.amazonaws.com unreachable.\n"
  (( id_ok==0 )) && msg+="• AWS identity not confirmed for '$SERVICE_USER'.\n"
  msg+="\nContinue anyway? (You can enter bucket/subfolder manually.)"
  if have_whiptail; then whiptail --title "Preflight checks" --yes-button "Continue" --no-button "Exit" --yesno "$msg" 14 74 || exit 2
  else echo -e "$msg"; read -rp "Continue? [Y/n]: " yn; [[ "${yn,,}" == "n" ]] && exit 2
  fi
}

# Load existing config if present
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || true

SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"

ensure_preflight_ok || true

# --- menus
sel=$(menu_select "Select server version" 15 74 5 \
  v4 "Server v4 (Apache / access.log*)" \
  v5 "Server v5 (OC4D or Cape Coast Castle)" \
)
[[ "$sel" == "v4" ]] && SERVER_VERSION="v1" || SERVER_VERSION="v2"

if [[ "$SERVER_VERSION" == "v2" ]]; then
  PYTHON_SCRIPT=$(menu_select "Select logs flavor (v2)" 12 74 5 \
    oc4d "OC4D logs (logv2.py)" \
    cape_coast_d "Cape Coast Castle logs (castle.py)" \
  )
else
  PYTHON_SCRIPT="oc4d"
fi

while :; do
  prompt_text "Device location (letters/numbers/_/-)" "${DEVICE_LOCATION}" DEVICE_LOCATION
  validate_device_location "$DEVICE_LOCATION" && break || say "Invalid location. Use 2-64 chars: [A-Za-z0-9_-]"
done

pick_bucket(){
  local out rc err="" opts=()
  out="$(aws_capture s3 ls 2>&1)"; rc=$?
  if (( rc != 0 )); then err="$out"; out=""; fi
  if [[ -z "$out" ]]; then
    local msg="Could not discover S3 buckets for user '$SERVICE_USER'.\n\nError:\n${err:-<no details>}\n\nSelect **Exit** to stop now, or **Manual** to type a bucket URL."
    if have_whiptail; then whiptail --title "Bucket discovery failed" --yes-button "Exit" --no-button "Manual" --yesno "$msg" 18 74 && exit 2
    else echo -e "$msg"; read -rp "Exit? [Y/n]: " yn; [[ "${yn,,}" != "n" ]] && exit 2
    fi
    while :; do
      prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
      S3_BUCKET="${S3_BUCKET%/}"
      [[ "$S3_BUCKET" =~ ^s3:// ]] && break || say "Bucket must start with s3://"
    done
    return 0
  fi
  while IFS= read -r line; do
    b="$(echo "$line" | awk '{print $3}')"; [[ -n "$b" ]] && opts+=( "$b" "$b" )
  done <<< "$out"
  opts+=( "CUSTOM" "Enter bucket manually" )
  choice="$(menu_select_cancelable "Select S3 bucket (discovered via AWS CLI)" 20 74 12 "${opts[@]}")"
  [[ "$choice" == "__EXIT__" ]] && exit 2
  if [[ "$choice" == "CUSTOM" ]]; then
    while :; do
      prompt_text "S3 bucket (e.g., s3://my-bucket)" "${S3_BUCKET}" S3_BUCKET
      S3_BUCKET="${S3_BUCKET%/}"
      [[ "$S3_BUCKET" =~ ^s3:// ]] && break || say "Bucket must start with s3://"
    done
  else
    S3_BUCKET="s3://$choice"
  fi
}
pick_bucket

pick_subfolder(){
  local bucket_name="${S3_BUCKET#s3://}"; bucket_name="${bucket_name%%/*}"
  local opts=( "NONE" "<bucket root>" "CUSTOM" "Enter subfolder manually" )
  local out rc
  out="$(aws_capture s3api list-objects-v2 --bucket "$bucket_name" --delimiter '/' --query 'CommonPrefixes[].Prefix' --output text 2>&1)"; rc=$?
  if (( rc == 0 )) && [[ -n "$out" && "$out" != "None" ]]; then
    while IFS= read -r p; do p="${p%/}"; [[ -n "$p" ]] && opts+=( "$p" "$p" ); done < <(printf '%s' "$out" | tr '\t' '\n' | sed '/^ *$/d')
  else
    out="$(aws_capture s3 ls "s3://$bucket_name/" 2>&1 || true)"
    while IFS= read -r line; do
      if [[ "$line" == PRE* ]]; then p="$(echo "$line" | awk '{print $2}' | sed 's:/$::')"; [[ -n "$p" ]] && opts+=( "$p" "$p" ); fi
    done <<< "$out"
  fi
  choice="$(menu_select_cancelable "Select S3 subfolder in s3://$bucket_name/" 20 74 12 "${opts[@]}")"
  [[ "$choice" == "__EXIT__" ]] && exit 2
  case "$choice" in
    NONE) S3_SUBFOLDER="" ;;
    CUSTOM) prompt_text "Subfolder (no leading slash; empty for root)" "${S3_SUBFOLDER}" S3_SUBFOLDER; S3_SUBFOLDER="$(sanitize_subfolder "$S3_SUBFOLDER")" ;;
    *) S3_SUBFOLDER="$choice" ;;
  esac
}
pick_subfolder
S3_SUBFOLDER="$(sanitize_subfolder "$S3_SUBFOLDER")"

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
  custom) while :; do prompt_text "Custom interval in seconds (>=300)" "${RUN_INTERVAL}" RUN_INTERVAL; [[ "$RUN_INTERVAL" =~ ^[0-9]+$ ]] && (( RUN_INTERVAL >= 300 )) && break || say "Enter a number >= 300."; done ;;
esac

summary=$(cat <<EOF
Service user   : $SERVICE_USER
Server version : $SERVER_VERSION
Logs flavor    : $PYTHON_SCRIPT
Device location: $DEVICE_LOCATION
S3 bucket      : $S3_BUCKET
S3 subfolder   : ${S3_SUBFOLDER:-<root>}
Schedule       : $SCHEDULE_TYPE (interval=${RUN_INTERVAL}s)
Config file    : $CONFIG_FILE
EOF
)
if have_whiptail; then whiptail --title "Confirm configuration" --msgbox "$summary" 19 74; else echo; echo "$summary"; echo; fi
confirm "Save configuration?" || { echo "Aborted."; exit 1; }

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
sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "$CONFIG_FILE"
sudo chmod 600 "$CONFIG_FILE"
say "💾 Saved: $CONFIG_FILE (owner: $SERVICE_USER)"

# ---------- robust live test (NO region flags) ----------
test_upload(){
  local bucket="${S3_BUCKET#s3://}"; bucket="${bucket%%/*}"
  local tsf="$(date +%Y%m%d_%H%M%S)"
  local key="${S3_SUBFOLDER:+$S3_SUBFOLDER/}RACHEL/_config_test_${tsf}.txt"

  # create test body as the SERVICE_USER so aws (run as pi) can read it
  local tmpfile
  if sudo -u "$SERVICE_USER" command -v mktemp >/dev/null 2>&1; then
    tmpfile="$(sudo -u "$SERVICE_USER" mktemp /tmp/cdn_auto_cfgtest.XXXXXX)"
    sudo -u "$SERVICE_USER" sh -c "printf 'cdn-auto test %s\n' '$tsf' > '$tmpfile'"
  else
    tmpfile="$(mktemp /tmp/cdn_auto_cfgtest.XXXXXX)"
    printf 'cdn-auto test %s\n' "$tsf" > "$tmpfile"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$tmpfile" 2>/dev/null || true
    chmod 600 "$tmpfile" 2>/dev/null || true
  fi
  trap 'rm -f "$tmpfile" 2>/dev/null || true' RETURN EXIT

  say "▶ Test upload → s3://$bucket/$key"
  if aws_su s3api put-object --bucket "$bucket" --key "$key" --body "$tmpfile" >/dev/null 2>&1; then
    say "✅ Test upload OK."; return 0
  fi

  # Some buckets require SSE by policy
  say "↻ Retrying with SSE-S3 (AES256)."
  if aws_su s3api put-object --bucket "$bucket" --key "$key" --body "$tmpfile" --server-side-encryption AES256 >/dev/null 2>&1; then
    say "✅ Test upload OK with SSE-S3."; return 0
  fi

  say "❌ Upload failed. AWS said:"
  aws_su s3api put-object --bucket "$bucket" --key "$key" --body "$tmpfile" 2>&1 | sed 's/^/   /'
  return 1
}

attempt=1; max_attempts=3
until test_upload; do
  say "Configuration test failed ($attempt/$max_attempts)."
  (( attempt >= max_attempts )) && { echo "❌ Giving up after $max_attempts attempts."; exit 2; }
  confirm "Open 'aws configure' for '$SERVICE_USER' now?" && { sudo -u "$SERVICE_USER" aws configure || true; }
  attempt=$((attempt+1))
done

# Timer override
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
