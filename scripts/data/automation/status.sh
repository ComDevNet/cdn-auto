#!/bin/sh
# cdn-auto status v7: POSIX sh compatible, sudo-aware, quiet on permission errors

SERVICE="v5-log-processor.service"
TIMER="v5-log-processor.timer"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." >/dev/null 2>&1 && pwd)
CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"
LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="$LOG_DIR/automation.log"
QUEUE_DIR="$PROJECT_ROOT/00_DATA/00_UPLOAD_QUEUE"
PROCESSED_DIR="$PROJECT_ROOT/00_DATA/00_PROCESSED"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }

hr() {
  cols=$(tput cols 2>/dev/null || echo 80)
  printf '%*s\n' "$cols" '' | tr ' ' '-'
}

have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@" 2>/dev/null
    return $?
  fi
  if have sudo && sudo -n true >/dev/null 2>&1; then
    sudo "$@" 2>/dev/null
    return $?
  fi
  "$@" 2>/dev/null
}

CFG_METHOD=""
read_config() {
  f="$CONFIG_FILE"
  if [ -r "$f" ]; then
    CFG_METHOD="direct"
    cat "$f" 2>/dev/null
    return 0
  fi
  if have sudo; then
    if sudo -n cat "$f" >/dev/null 2>&1; then
      CFG_METHOD="sudo-n"
      sudo -n cat "$f" 2>/dev/null
      return $?
    elif sudo cat "$f" >/dev/null 2>&1; then
      CFG_METHOD="sudo"
      sudo cat "$f" 2>/dev/null
      return $?
    fi
  fi
  CFG_METHOD="unreadable"
  return 1
}

cfg_get() {
  key="$1"
  content="$(read_config 2>/dev/null || true)"
  echo "$content" | awk -F= -v k="$key" 'index($0,k"=")==1 { $1=""; sub(/^=/,"",$0); print $0; exit }' | sed 's/^"//; s/"$//'
}

hr
echo "cdn-auto STATUS  ($(date))"
hr
echo "Project root : $PROJECT_ROOT"
echo "Config file  : $CONFIG_FILE"
echo "Config read  : ${CFG_METHOD:-<not yet>}"

echo
echo "CONFIG"
if content="$(read_config)"; then
  SERVER_VERSION=$(echo "$content" | awk -F= '/^SERVER_VERSION=/{print $2}' | sed 's/^"//; s/"$//')
  DEVICE_LOCATION=$(echo "$content" | awk -F= '/^DEVICE_LOCATION=/{print $2}' | sed 's/^"//; s/"$//')
  PYTHON_SCRIPT=$(echo "$content" | awk -F= '/^PYTHON_SCRIPT=/{print $2}' | sed 's/^"//; s/"$//')
  S3_BUCKET=$(echo "$content" | awk -F= '/^S3_BUCKET=/{print $2}' | sed 's/^"//; s/"$//')
  S3_SUBFOLDER=$(echo "$content" | awk -F= '/^S3_SUBFOLDER=/{print $2}' | sed 's/^"//; s/"$//')
  AWS_PROFILE=$(echo "$content" | awk -F= '/^AWS_PROFILE=/{print $2}' | sed 's/^"//; s/"$//')
  AWS_REGION=$(echo "$content" | awk -F= '/^AWS_REGION=/{print $2}' | sed 's/^"//; s/"$//')
  echo "  SERVER_VERSION = ${SERVER_VERSION:-<unset>}"
  echo "  PYTHON_SCRIPT  = ${PYTHON_SCRIPT:-<unset>}"
  echo "  DEVICE_LOCATION= ${DEVICE_LOCATION:-<unset>}"
  echo "  S3_BUCKET      = ${S3_BUCKET:-<unset>}"
  echo "  S3_SUBFOLDER   = ${S3_SUBFOLDER:-<unset>}"
  echo "  AWS_PROFILE    = ${AWS_PROFILE:-<none>}"
  echo "  AWS_REGION     = ${AWS_REGION:-<none>}"
else
  echo "  (missing or unreadable)"
fi
echo

echo "SYSTEMD"
if have systemctl; then
  T_ACTIVE="$(as_root systemctl show "$TIMER" -p ActiveState --value)"
  T_LAST="$(as_root systemctl show "$TIMER" -p LastTriggerUSec --value)"
  T_NEXT="$(as_root systemctl show "$TIMER" -p NextElapseUSecRealtime --value)"
  [ -z "$T_NEXT" ] && T_NEXT="$(as_root systemctl show "$TIMER" -p NextElapseUSec --value)"
  echo "  Timer      : $TIMER (${T_ACTIVE:-unknown})"
  echo "  Last run   : ${T_LAST:-<unknown>}"
  echo "  Next run   : ${T_NEXT:-<unknown>}"
  S_ACTIVE="$(as_root systemctl show "$SERVICE" -p ActiveState --value)"
  S_SUB="$(as_root systemctl show "$SERVICE" -p SubState --value)"
  S_RC="$(as_root systemctl show "$SERVICE" -p ExecMainStatus --value)"
  echo "  Service    : $SERVICE (${S_ACTIVE:-unknown}/${S_SUB:-unknown}, last exit=${S_RC:-?})"
else
  echo "  systemctl not available."
fi
echo

echo "QUEUE"
mkdir -p "$QUEUE_DIR" 2>/dev/null
Q_COUNT="$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.csv' 2>/dev/null | wc -l | tr -d ' ')"
echo "  Directory  : $QUEUE_DIR"
echo "  Files      : $Q_COUNT queued CSV(s)"
if [ "$Q_COUNT" != "0" ]; then
  find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.csv' -printf '    %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort
fi
echo

echo "PROCESSED"
if [ -d "$PROCESSED_DIR" ]; then
  LATEST_DIR="$(find "$PROCESSED_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  if [ -n "$LATEST_DIR" ]; then
    echo "  Latest dir : $LATEST_DIR"
    find "$LATEST_DIR" -maxdepth 1 -type f -name '*.csv' -printf '    %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort
  else
    echo "  No processed runs yet."
  fi
else
  echo "  $PROCESSED_DIR not found."
fi
echo

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

echo "AWS"
if have aws; then
  WHO="$(as_root aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"
  if [ -z "$WHO" ]; then
    WHO="$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"
  fi
  if [ -z "$WHO" ]; then
    echo "  Identity   : <unavailable>"
  else
    echo "  Identity   : $WHO"
  fi
  if [ -n "$S3_BUCKET" ]; then
    BNAME="${S3_BUCKET#s3://}"; BNAME="${BNAME%%/*}"
    if aws s3api head-bucket --bucket "$BNAME" >/dev/null 2>&1; then
      echo "  Bucket     : $BNAME (reachable)"
    else
      echo "  Bucket     : $BNAME (head-bucket denied/not reachable)"
    fi
    if [ -n "$S3_SUBFOLDER" ]; then
      echo "  Prefix     : ${S3_SUBFOLDER}/RACHEL/"
    else
      echo "  Prefix     : RACHEL/"
    fi
  fi
else
  echo "  AWS CLI    : not installed"
fi
echo

echo "LOGS (last 50 lines)"
if have journalctl; then
  as_root journalctl -u "$SERVICE" --no-pager -n 50 2>/dev/null || true
elif [ -f "$LOG_FILE" ]; then
  as_root tail -n 50 "$LOG_FILE" 2>/dev/null || true
else
  echo "  No logs available."
fi
echo
hr
echo "Done."

# Wait for Enter only if we're attached to a terminal
if [ -t 0 ]; then
  printf "\nPress Enter to return to the main screen..."
  IFS= read -r _
fi

# Re-enter the main menu reliably (works even if the menu used 'exec' to launch us)
MAIN="$SCRIPT_DIR/main.sh"
if [ -x "$MAIN" ]; then
  exec "$MAIN"
fi

exit 0

