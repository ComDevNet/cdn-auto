#!/bin/bash
# cdn-auto status: show service/timer/config/queue/AWS info without noisy permission errors
# Safe to run as any user; escalates with sudo -n where helpful, but never prints sudo errors.
set -uo pipefail

# --- constants ---
SERVICE="v5-log-processor.service"
TIMER="v5-log-processor.timer"
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"
LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="$LOG_DIR/automation.log"
QUEUE_DIR="$PROJECT_ROOT/00_DATA/00_UPLOAD_QUEUE"
PROCESSED_DIR="$PROJECT_ROOT/00_DATA/00_PROCESSED"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }
hr() { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }

have() { command -v "$1" >/dev/null 2>&1; }

# Run with sudo if available & no password needed; otherwise run normally.
as_root() {
  if [[ $EUID -eq 0 ]]; then "$@" 2>/dev/null; return $?
  fi
  if have sudo && sudo -n true >/dev/null 2>&1; then
    sudo "$@" 2>/dev/null; return $?
  fi
  "$@" 2>/dev/null
}

# Run as the systemd service user (from unit), or fallback to 'pi'
service_user() {
  local unit="/etc/systemd/system/${SERVICE}"
  local u
  u="$(awk -F= '/^User=/{print $2}' "$unit" 2>/dev/null | tail -n1)"
  [[ -n "$u" ]] && echo "$u" || echo "pi"
}

as_service_user() {
  local su; su="$(service_user)"
  if [[ "$su" == "$(id -un 2>/dev/null)" ]]; then
    "$@" 2>/dev/null; return $?
  fi
  if have sudo && sudo -n true >/dev/null 2>&1; then
    sudo -u "$su" "$@" 2>/dev/null; return $?
  fi
  "$@" 2>/dev/null
}

# read file content silently (trying with sudo if needed)
read_file() {
  local f="$1"
  if [[ -r "$f" ]]; then cat "$f" 2>/dev/null; return 0; fi
  as_root cat "$f"
}

# Extract KEY=value (double-quoted or bare) from CONFIG_FILE
cfg_get() {
  local key="$1" val content
  content="$(read_file "$CONFIG_FILE")" || { echo ""; return 1; }
  val="$(printf '%s\n' "$content" | awk -F= -v k="^"$(printf "%q" "$key")"="$" ' $0 ~ k { $1=""; sub(/^=/,"",$0); print $0; exit }' )"
  # strip surrounding quotes if present
  val="${val%$'\r'}"
  val="${val%\"}"; val="${val#\"}"
  echo "$val"
}

# --- header ---
hr
echo "cdn-auto STATUS  ($(date))"
hr
echo "Project root : $PROJECT_ROOT"
echo "Config file  : $CONFIG_FILE"
echo "Service user : $(service_user)"
echo

# --- Config summary ---
echo "CONFIG"
if [[ -f "$CONFIG_FILE" ]]; then
  SERVER_VERSION="$(cfg_get SERVER_VERSION)"
  DEVICE_LOCATION="$(cfg_get DEVICE_LOCATION)"
  PYTHON_SCRIPT="$(cfg_get PYTHON_SCRIPT)"
  S3_BUCKET="$(cfg_get S3_BUCKET)"
  S3_SUBFOLDER="$(cfg_get S3_SUBFOLDER)"
  AWS_PROFILE="$(cfg_get AWS_PROFILE)"
  AWS_REGION="$(cfg_get AWS_REGION)"
  echo "  SERVER_VERSION = ${SERVER_VERSION:-<unset>}"
  echo "  PYTHON_SCRIPT  = ${PYTHON_SCRIPT:-<unset>}"
  echo "  DEVICE_LOCATION= ${DEVICE_LOCATION:-<unset>}"
  echo "  S3_BUCKET      = ${S3_BUCKET:-<unset>}"
  echo "  S3_SUBFOLDER   = ${S3_SUBFOLDER:-<unset>}"
  echo "  AWS_PROFILE    = ${AWS_PROFILE:-<none>}"
  echo "  AWS_REGION     = ${AWS_REGION:-<none>}"
else
  echo "  (missing)"
fi
echo

# --- Systemd status ---
echo "SYSTEMD"
if have systemctl; then
  # Timer summaries
  T_ACTIVE="$(as_root systemctl show "$TIMER" -p ActiveState --value)"
  T_LAST="$(as_root systemctl show "$TIMER" -p LastTriggerUSec --value)"
  T_NEXT="$(as_root systemctl show "$TIMER" -p NextElapseUSecRealtime --value)"
  [[ -z "$T_NEXT" ]] && T_NEXT="$(as_root systemctl show "$TIMER" -p NextElapseUSec --value)"
  echo "  Timer      : $TIMER ($T_ACTIVE)"
  echo "  Last run   : ${T_LAST:-<unknown>}"
  echo "  Next run   : ${T_NEXT:-<unknown>}"
  # Service summaries
  S_ACTIVE="$(as_root systemctl show "$SERVICE" -p ActiveState --value)"
  S_SUB="$(as_root systemctl show "$SERVICE" -p SubState --value)"
  S_RC="$(as_root systemctl show "$SERVICE" -p ExecMainStatus --value)"
  echo "  Service    : $SERVICE ($S_ACTIVE/$S_SUB, last exit=$S_RC)"
else
  echo "  systemctl not available."
fi
echo

# --- Queue status ---
echo "QUEUE"
mkdir -p "$QUEUE_DIR" 2>/dev/null
Q_COUNT="$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.csv' 2>/dev/null | wc -l | tr -d ' ')"
echo "  Directory  : $QUEUE_DIR"
echo "  Files      : $Q_COUNT queued CSV(s)"
if [[ "$Q_COUNT" != "0" ]]; then
  find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.csv' -printf '    %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort
fi
echo

# --- Latest processed outputs ---
echo "PROCESSED"
if [[ -d "$PROCESSED_DIR" ]]; then
  LATEST_DIR="$(find "$PROCESSED_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  if [[ -n "$LATEST_DIR" ]]; then
    echo "  Latest dir : $LATEST_DIR"
    find "$LATEST_DIR" -maxdepth 1 -type f -name '*.csv' -printf '    %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort
  else
    echo "  No processed runs yet."
  fi
else
  echo "  $PROCESSED_DIR not found."
fi
echo

# --- Internet connectivity (no S3 perms needed) ---
echo "CONNECTIVITY"
if getent hosts s3.amazonaws.com >/dev/null 2>&1; then
  echo "  DNS        : OK (s3.amazonaws.com)"
else
  echo "  DNS        : FAIL (cannot resolve s3.amazonaws.com)"
fi
if have curl && timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1; then
  echo "  HTTPS      : OK (S3 endpoint reachable)"
else
  echo "  HTTPS      : FAIL (cannot reach S3 endpoint)"
fi
echo

# --- AWS identity & S3 checks (soft; never print raw errors) ---
echo "AWS"
if have aws; then
  WHO="$(as_service_user aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"
  if [[ -n "$WHO" ]]; then
    echo "  Identity   : $WHO"
  else
    echo "  Identity   : <unavailable; credentials missing or invalid for service user '$(service_user)'>"
  fi
  # Head bucket (does not require listing; may still 403 if bucket not owned/allowed)
  if [[ -f "$CONFIG_FILE" ]]; then
    BUCKET_URL="$(cfg_get S3_BUCKET)"
    SUBFOLDER="$(cfg_get S3_SUBFOLDER)"
    if [[ -n "$BUCKET_URL" ]]; then
      BNAME="${BUCKET_URL#s3://}"; BNAME="${BNAME%%/*}"
      if as_service_user aws s3api head-bucket --bucket "$BNAME" >/dev/null 2>&1; then
        echo "  Bucket     : $BNAME (reachable)"
      else
        echo "  Bucket     : $BNAME (head-bucket denied or not reachable; may still allow PutObject)"
      fi
      if [[ -n "$SUBFOLDER" ]]; then
        echo "  Prefix     : ${SUBFOLDER}/RACHEL/"
      else
        echo "  Prefix     : RACHEL/"
      fi
    fi
  fi
else
  echo "  AWS CLI    : not installed"
fi
echo

# --- Recent logs (journalctl preferred, fallback to file) ---
echo "LOGS (last 50 lines)"
if have journalctl; then
  as_root journalctl -u "$SERVICE" --no-pager -n 50 2>/dev/null || true
elif [[ -f "$LOG_FILE" ]]; then
  as_root tail -n 50 "$LOG_FILE" 2>/dev/null || true
else
  echo "  No logs available."
fi
echo

hr
echo "Done."
