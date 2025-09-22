#!/bin/bash
# Non-interactive automation runner for Raspberry Pi
# Reads ./config/automation.conf and runs: collect → process → filter → upload
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

# --- Locate project root ---
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  log "❌ Missing config at $CONFIG_FILE. Run: sudo ./scripts/data/automation/configure.sh"
  exit 1
fi
if [[ ! -r "$CONFIG_FILE" ]]; then
  OWNER="$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null || echo '?')"
  PERM="$(stat -c '%A' "$CONFIG_FILE" 2>/dev/null || echo '?')"
  log "❌ Config not readable ($CONFIG_FILE). Owner=$OWNER Perm=$PERM"
  log "   Fix: sudo chown pi:pi $CONFIG_FILE && sudo chmod 600 $CONFIG_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Export optional AWS env if provided
export AWS_PROFILE="${AWS_PROFILE:-}"
export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

# Defaults
SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}" # oc4d | cape_coast_d (v2 only)
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"

SERVER_VERSION="$(echo "$SERVER_VERSION" | tr '[:upper:]' '[:lower:]')"
PYTHON_SCRIPT="$(echo "$PYTHON_SCRIPT" | tr '[:upper:]' '[:lower:]')"

DATA_DIR="$PROJECT_ROOT/00_DATA"
PROCESSED_ROOT="$DATA_DIR/00_PROCESSED"
QUEUE_DIR="$DATA_DIR/00_UPLOAD_QUEUE"
mkdir -p "$DATA_DIR" "$PROCESSED_ROOT" "$QUEUE_DIR"

TODAY_YMD="$(date '+%Y_%m_%d')"
NEW_FOLDER="${DEVICE_LOCATION}_logs_${TODAY_YMD}"
COLLECT_DIR="$DATA_DIR/$NEW_FOLDER"

join_path() { local a="${1%/}" b="${2#/}"; echo "${a}/${b}"; }

# Simple internet check (does not require AWS perms)
has_internet() {
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  if command -v curl >/dev/null 2>&1; then
    timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || return 1
  fi
  return 0
}

aws_cp() { env AWS_PROFILE="${AWS_PROFILE:-}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}" aws s3 cp "$@"; }

upload_one() {
  local file_path="$1"
  local remote_base="${S3_BUCKET%/}"
  [[ -n "$S3_SUBFOLDER" ]] && remote_base="$(join_path "$remote_base" "$S3_SUBFOLDER")"
  local remote_path="$(join_path "$remote_base" "RACHEL/$(basename "$file_path")")"
  log "⬆️  Uploading $(basename "$file_path") → $remote_path"
  if timeout 180s aws_cp "$file_path" "$remote_path"; then
    log "✅ Uploaded: $(basename "$file_path")"; return 0
  else
    log "⚠️ Upload failed, will queue: $(basename "$file_path")"; return 1
  fi
}

log "📁 Collect → $COLLECT_DIR  (server=$SERVER_VERSION, device=$DEVICE_LOCATION)"
mkdir -p "$COLLECT_DIR"

case "$SERVER_VERSION" in
  v1|server\ v4|v4)
    LOG_DIR="/var/log/apache2"
    find "$LOG_DIR" -type f -name 'access.log*' -exec cp -n {} "$COLLECT_DIR"/ \;
    ;;
  v2|server\ v5|v5)
    LOG_DIR="/var/log/oc4d"
    find "$LOG_DIR" -type f \( \
       \( -name 'oc4d-*.log' ! -name 'oc4d-exceptions-*.log' \) -o \
       \( -name 'capecoastcastle-*.log' ! -name 'capecoastcastle-exceptions-*.log' \) -o \
       -name '*.gz' \) -exec cp -n {} "$COLLECT_DIR"/ \;
    ;;
  *)
    log "❌ Unknown SERVER_VERSION '$SERVER_VERSION'"; exit 1;;
esac

shopt -s nullglob
for gz in "$COLLECT_DIR"/*.gz; do gzip -df "$gz" || true; done
shopt -u nullglob

PROCESSOR=""
case "$SERVER_VERSION" in
  v1|v4) PROCESSOR="scripts/data/process/processors/log.py" ;;
  v2|v5|server\ v5)
    case "$PYTHON_SCRIPT" in
      oc4d) PROCESSOR="scripts/data/process/processors/logv2.py" ;;
      cape_coast_d) PROCESSOR="scripts/data/process/processors/castle.py" ;;
      *) PROCESSOR="scripts/data/process/processors/logv2.py" ;;
    esac
    ;;
esac

log "🐍 Process → $PROCESSOR  (folder=$NEW_FOLDER)"
python3 "$PROCESSOR" "$NEW_FOLDER"

PROCESSED_DIR="$PROCESSED_ROOT/$NEW_FOLDER"
SUMMARY="$PROCESSED_DIR/summary.csv"
if [[ ! -s "$SUMMARY" ]]; then
  log "❌ Missing or empty summary at $SUMMARY"; exit 1
fi

MONTH="$(echo "$NEW_FOLDER" | awk -F'_' '{print $(NF-1)}' || true)"
if ! [[ "$MONTH" =~ ^[0-9]{2}$ ]]; then MONTH="$(date +%m)"; fi
log "🧮 Filter month=$MONTH → final CSV"
python3 scripts/data/upload/process_csv.py "$PROCESSED_DIR" "$DEVICE_LOCATION" "$MONTH" "summary.csv"

shopt -s nullglob
FINAL_CAND=( "$PROCESSED_DIR/${DEVICE_LOCATION}_${MONTH}_"*"_access_logs.csv" )
shopt -u nullglob
if [[ ${#FINAL_CAND[@]} -eq 0 ]]; then
  log "❌ Could not locate final CSV after filtering."; exit 1
fi
FINAL_CSV="${FINAL_CAND[0]}"
log "📦 Final CSV: $(basename "$FINAL_CSV")"

# Upload logic with offline queue
if has_internet; then
  log "🌐 Internet OK. Flushing queue…"
  shopt -s nullglob
  for q in "$QUEUE_DIR"/*.csv; do
    if upload_one "$q"; then rm -f "$q"; else log "Leaving queued: $(basename "$q")"; fi
  done
  shopt -u nullglob
  if upload_one "$FINAL_CSV"; then
    log "✅ Run finished — upload complete."
  else
    log "⚠️ Upload failed; queueing new file."; cp -f "$FINAL_CSV" "$QUEUE_DIR/"
  fi
else
  log "📵 No internet. Queueing new file."; cp -f "$FINAL_CSV" "$QUEUE_DIR/"
fi
