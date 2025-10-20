#!/bin/bash
# Runner with per-bucket region autodetect (no global AWS config needed)
set -euo pipefail
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

load_config() {
  local src="$CONFIG_FILE"
  local tmp=""
  if [[ -r "$src" ]]; then source "$src"; log "⚙️  Config loaded (direct): $src"; return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="/tmp/cdn_auto_conf.$$.sh"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp"; source "$tmp"; rm -f "$tmp"; log "⚙️  Config loaded (sudo): $src"; return 0
    fi
  fi
  log "❌ Cannot read config: $src"; exit 1
}
load_config

# Unset empty AWS env so CLI uses its defaults; we will supply region per call.
[[ -n "${AWS_PROFILE:-}" ]] && export AWS_PROFILE || unset AWS_PROFILE
[[ -n "${AWS_REGION:-}" ]] && export AWS_DEFAULT_REGION="$AWS_REGION" || unset AWS_DEFAULT_REGION

SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}" # Default schedule if not in config

DATA_DIR="$PROJECT_ROOT/00_DATA"
PROCESSED_ROOT="$DATA_DIR/00_PROCESSED"
QUEUE_DIR="$DATA_DIR/00_UPLOAD_QUEUE"
mkdir -p "$DATA_DIR" "$PROCESSED_ROOT" "$QUEUE_DIR"

TODAY_YMD="$(date '+%Y_%m_%d')"
NEW_FOLDER="${DEVICE_LOCATION}_logs_${TODAY_YMD}"
COLLECT_DIR="$DATA_DIR/$NEW_FOLDER"

join_path() { local a="${1%/}" b="${2#/}"; echo "${a}/${b}"; }

has_internet() {
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  if command -v curl >/dev/null 2>&1; then timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || return 1; fi
  return 0
}

bucket_name() { local bn="${S3_BUCKET#s3://}"; echo "${bn%%/*}"; }

bucket_region() {
  local b; b="$(bucket_name)"
  local reg=""
  reg="$(aws --region us-east-1 s3api get-bucket-location --bucket "$b" --query 'LocationConstraint' --output text 2>/dev/null || true)"
  if [[ -z "$reg" || "$reg" == "None" ]]; then reg="us-east-1"; fi
  if [[ "$reg" == "EU" ]]; then reg="eu-west-1"; fi
  # Curl fallback
  if [[ -z "$reg" ]] && command -v curl >/dev/null 2>&1; then
    reg="$(curl -sI "https://${b}.s3.amazonaws.com/" | tr -d '\r' | awk -F': ' 'BEGIN{IGNORECASE=1}/^x-amz-bucket-region:/{print $2;exit}')"
  fi
  echo "$reg"
}

aws_cp_region() {
  local file="$1" dest="$2" reg; reg="$(bucket_region)"
  aws --region "$reg" s3 cp "$file" "$dest"
}

upload_one() {
  local file_path="$1"
  local remote_base="${S3_BUCKET%/}"
  [[ -n "$S3_SUBFOLDER" ]] && remote_base="$(join_path "$remote_base" "$S3_SUBFOLDER")"
  local remote_path="$(join_path "$remote_base" "RACHEL/$(basename "$file_path")")"
  log "⬆️  Uploading $(basename "$file_path") → $remote_path"
  local out rc
  out="$(aws_cp_region "$file_path" "$remote_path" 2>&1)"; rc=$?
  if (( rc == 0 )); then log "✅ Uploaded: $(basename "$file_path")"; return 0
  else log "❌ Upload failed for $(basename "$file_path"): $out"; return 1; fi
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
  v3|dhub|d-hub)
    LOG_DIR="/var/log/dhub"
    find "$LOG_DIR" -type f -name '*.log' -exec cp -n {} "$COLLECT_DIR"/ \;
    ;;
  *) log "❌ Unknown SERVER_VERSION '$SERVER_VERSION'"; exit 1;;
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
  v3|dhub|d-hub) PROCESSOR="scripts/data/process/processors/dhub.py" ;;
esac
log "🐍 Process → $PROCESSOR  (folder=$NEW_FOLDER)"
python3 "$PROCESSOR" "$NEW_FOLDER"

PROCESSED_DIR="$PROCESSED_ROOT/$NEW_FOLDER"
SUMMARY="$PROCESSED_DIR/summary.csv"
if [[ ! -s "$SUMMARY" ]]; then log "ℹ️ No new data in summary.csv. Nothing to process."; exit 0; fi

FINAL_CSV="" # This variable will hold the path to the final file

# --- Intelligent Filtering based on configured schedule ---
case "$SCHEDULE_TYPE" in
  hourly|daily|weekly)
    log "🧮 Filtering for '$SCHEDULE_TYPE' schedule..."
    # The python script will print the filename if it creates one.
    FINAL_CSV_BASENAME=$(python3 "scripts/data/automation/filter_time_based.py" "$PROCESSED_DIR" "$DEVICE_LOCATION" "$SCHEDULE_TYPE")
    if [[ -n "$FINAL_CSV_BASENAME" ]]; then
        FINAL_CSV="$PROCESSED_DIR/$FINAL_CSV_BASENAME"
    fi
    ;;

  monthly)
    log "🧮 Filtering for 'monthly' schedule..."
    MONTH="$(date +%m)"
    # The python script will print the filename when called with 'filename' mode.
    FINAL_CSV_BASENAME=$(python3 scripts/data/upload/process_csv.py "$PROCESSED_DIR" "$DEVICE_LOCATION" "$MONTH" "summary.csv" "filename")
    if [[ -n "$FINAL_CSV_BASENAME" ]]; then
        FINAL_CSV="$PROCESSED_DIR/$FINAL_CSV_BASENAME"
    fi
    ;;

  *)
    log "❌ Unknown SCHEDULE_TYPE '$SCHEDULE_TYPE' in config. Cannot filter."
    exit 1
    ;;
esac

# Check if a final file was actually created by the filtering process
if [[ -z "$FINAL_CSV" || ! -f "$FINAL_CSV" ]]; then
  log "ℹ️ No new entries matched the time period. Run finished."
  exit 0
fi

log "📦 Final CSV: $(basename "$FINAL_CSV")"

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

