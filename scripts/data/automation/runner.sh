#!/bin/bash
# Runner: fix AWS_PROFILE handling (unset when empty) + sudo-aware config load
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
  if [[ -r "$src" ]]; then
    # shellcheck disable=SC1090
    source "$src"
    log "⚙️  Config loaded (direct): $src"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="/tmp/cdn_auto_conf.$$.sh"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp"
      # shellcheck disable=SC1090
      source "$tmp"
      rm -f "$tmp"
      log "⚙️  Config loaded (sudo): $src"
      return 0
    fi
  fi
  local owner perm
  owner="$(stat -c '%U' "$src" 2>/dev/null || echo '?')"
  perm="$(stat -c '%A' "$src" 2>/dev/null || echo '?')"
  log "❌ Cannot read config: $src (owner=$owner perm=$perm)"
  log "   Fix: sudo chown $(id -un):$(id -gn) \"$src\" && sudo chmod 600 \"$src\""
  exit 1
}
load_config

# --- Normalize AWS env ---
# Only export when non-empty; otherwise unset so AWS CLI uses default credentials
if [[ -n "${AWS_PROFILE:-}" ]]; then
  export AWS_PROFILE
else
  unset AWS_PROFILE
fi
# Prefer AWS_REGION from config; fall back to existing AWS_DEFAULT_REGION; otherwise unset
if [[ -n "${AWS_REGION:-}" ]]; then
  export AWS_DEFAULT_REGION="$AWS_REGION"
elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
  export AWS_DEFAULT_REGION
else
  unset AWS_DEFAULT_REGION
fi

# Defaults
SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
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

has_internet() {
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  if command -v curl >/dev/null 2>&1; then timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || return 1; fi
  return 0
}

aws_cp() {
  # use env-based profile/region only if set (we normalized above)
  aws s3 cp "$@"
}

upload_one() {
  local file_path="$1"
  local remote_base="${S3_BUCKET%/}"
  [[ -n "$S3_SUBFOLDER" ]] && remote_base="$(join_path "$remote_base" "$S3_SUBFOLDER")"
  local remote_path="$(join_path "$remote_base" "RACHEL/$(basename "$file_path")")"
  log "⬆️  Uploading $(basename "$file_path") → $remote_path"
  local out rc
  out="$(aws_cp "$file_path" "$remote_path" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    log "✅ Uploaded: $(basename "$file_path")"
    return 0
  else
    log "❌ Upload failed for $(basename "$file_path"): $out"
    return 1
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
esac
log "🐍 Process → $PROCESSOR  (folder=$NEW_FOLDER)"
python3 "$PROCESSOR" "$NEW_FOLDER"

PROCESSED_DIR="$PROCESSED_ROOT/$NEW_FOLDER"
SUMMARY="$PROCESSED_DIR/summary.csv"
if [[ ! -s "$SUMMARY" ]]; then
  log "❌ Missing or empty summary at $SUMMARY"
  exit 1
fi

MONTH="$(echo "$NEW_FOLDER" | awk -F'_' '{print $(NF-1)}' || true)"
if ! [[ "$MONTH" =~ ^[0-9]{2}$ ]]; then MONTH="$(date +%m)"; fi
log "🧮 Filter month=$MONTH → final CSV"
python3 scripts/data/upload/process_csv.py "$PROCESSED_DIR" "$DEVICE_LOCATION" "$MONTH" "summary.csv"

shopt -s nullglob
FINAL_CAND=( "$PROCESSED_DIR/${DEVICE_LOCATION}_${MONTH}_"*"_access_logs.csv" )
shopt -u nullglob
if [[ ${#FINAL_CAND[@]} -eq 0 ]]; then
  log "❌ Could not locate final CSV after filtering."
  exit 1
fi
FINAL_CSV="${FINAL_CAND[0]}"
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
