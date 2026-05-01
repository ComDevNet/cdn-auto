#!/bin/bash
# Runner with per-bucket region autodetect and Kolibri summary export support.
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/data/lib/s3_helpers.sh"
source "$PROJECT_ROOT/scripts/data/lib/kolibri_helpers.sh"

CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

load_config() {
  local src="$CONFIG_FILE"
  local tmp=""
  if [[ -r "$src" ]]; then
    source "$src"
    log "[config] Loaded (direct): $src"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="/tmp/cdn_auto_conf.$$.sh"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp"
      source "$tmp"
      rm -f "$tmp"
      log "[config] Loaded (sudo): $src"
      return 0
    fi
  fi
  log "[error] Cannot read config: $src"
  exit 1
}
load_config

[[ -n "${AWS_PROFILE:-}" ]] && export AWS_PROFILE || unset AWS_PROFILE
[[ -n "${AWS_REGION:-}" ]] && export AWS_DEFAULT_REGION="$AWS_REGION" || unset AWS_DEFAULT_REGION

SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
RACHEL_SUBFOLDER="${RACHEL_SUBFOLDER:-}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"
KOLIBRI_FACILITY_ID="${KOLIBRI_FACILITY_ID:-}"

DATA_DIR="$PROJECT_ROOT/00_DATA"
PROCESSED_ROOT="$DATA_DIR/00_PROCESSED"
QUEUE_DIR="$DATA_DIR/00_UPLOAD_QUEUE"
KOLIBRI_EXPORT_DIR="$DATA_DIR/00_KOLIBRI_EXPORTS"
mkdir -p "$DATA_DIR" "$PROCESSED_ROOT" "$QUEUE_DIR" "$KOLIBRI_EXPORT_DIR"
prepare_queue_dirs "$QUEUE_DIR"

TODAY_YMD="$(date '+%Y_%m_%d')"
NEW_FOLDER="${DEVICE_LOCATION}_logs_${TODAY_YMD}"
COLLECT_DIR="$DATA_DIR/$NEW_FOLDER"

has_internet() {
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  if command -v curl >/dev/null 2>&1; then
    timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || return 1
  fi
  return 0
}

log "[collect] $COLLECT_DIR  (server=$SERVER_VERSION, device=$DEVICE_LOCATION)"
mkdir -p "$COLLECT_DIR"
case "$SERVER_VERSION" in
  v1|server\ v4|v4)
    LOG_DIR="/var/log/apache2"
    find "$LOG_DIR" -type f -name 'access.log*' -exec cp {} "$COLLECT_DIR"/ \;
    ;;
  v2|server\ v5|v5)
    LOG_DIR="/var/log/oc4d"
    find "$LOG_DIR" -type f \( \
       \( -name 'oc4d-*.log' ! -name 'oc4d-exceptions-*.log' \) -o \
       \( -name 'capecoastcastle-*.log' ! -name 'capecoastcastle-exceptions-*.log' \) -o \
       -name '*.gz' \) -exec cp {} "$COLLECT_DIR"/ \;
    ;;
  v3|dhub|d-hub)
    LOG_DIR="/var/log/dhub"
    find "$LOG_DIR" -type f -name '*.log' -exec cp {} "$COLLECT_DIR"/ \;
    ;;
  server\ v6|v6)
    LOG_DIR="/var/log/oc4d"
    find "$LOG_DIR" -type f -name 'oc4d-*.log' ! -name 'oc4d-exceptions-*.log' -exec cp {} "$COLLECT_DIR"/ \;
    ;;
  *)
    log "[error] Unknown SERVER_VERSION '$SERVER_VERSION'"
    exit 1
    ;;
esac

shopt -s nullglob
for gz in "$COLLECT_DIR"/*.gz; do
  gzip -df "$gz" || true
done
shopt -u nullglob

PROCESSOR=""
case "$SERVER_VERSION" in
  v1|v4)
    PROCESSOR="scripts/data/process/processors/log.py"
    ;;
  v2|v5|server\ v5)
    case "$PYTHON_SCRIPT" in
      oc4d) PROCESSOR="scripts/data/process/processors/logv2.py" ;;
      cape_coast_d) PROCESSOR="scripts/data/process/processors/castle.py" ;;
      *) PROCESSOR="scripts/data/process/processors/logv2.py" ;;
    esac
    ;;
  v3|dhub|d-hub)
    PROCESSOR="scripts/data/process/processors/dhub.py"
    ;;
  server\ v6|v6)
    PROCESSOR="scripts/data/process/processors/log-v6.py"
    ;;
esac

log "[process] $PROCESSOR  (folder=$NEW_FOLDER)"
python3 "$PROCESSOR" "$NEW_FOLDER"

PROCESSED_DIR="$PROCESSED_ROOT/$NEW_FOLDER"
SUMMARY="$PROCESSED_DIR/summary.csv"
FINAL_CSV=""

if [[ ! -s "$SUMMARY" ]]; then
  log "[info] No new data in summary.csv. Skipping RACHEL upload for this run."
else
  case "$SCHEDULE_TYPE" in
    hourly|daily|weekly|monthly|yearly|custom)
      log "[filter] Schedule '$SCHEDULE_TYPE'"
      FINAL_CSV_BASENAME="$(python3 "scripts/data/automation/filter_time_based.py" "$PROCESSED_DIR" "$DEVICE_LOCATION" "$SCHEDULE_TYPE" "$RUN_INTERVAL")"
      if [[ -n "$FINAL_CSV_BASENAME" ]]; then
        FINAL_CSV="$PROCESSED_DIR/$FINAL_CSV_BASENAME"
      fi
      ;;
    *)
      log "[error] Unknown SCHEDULE_TYPE '$SCHEDULE_TYPE' in config. Cannot filter."
      exit 1
      ;;
  esac

  if [[ -n "$FINAL_CSV" && -f "$FINAL_CSV" ]]; then
    FILE_SIZE="$(du -h "$FINAL_CSV" | cut -f1)"
    log "[upload] Prepared $(basename "$FINAL_CSV") ($FILE_SIZE)"
  else
    FINAL_CSV=""
    log "[info] No new entries matched the time period. Skipping RACHEL upload for this run."
  fi
fi

ONLINE=0
if has_internet; then
  ONLINE=1
  log "[online] Internet OK. Flushing queued uploads..."
  flush_all_queues "$QUEUE_DIR" || log "[warn] Some queued files could not be flushed; continuing with new exports."
else
  log "[offline] No internet. New exports will be queued."
fi

if [[ -n "$FINAL_CSV" ]]; then
  if (( ONLINE )); then
    if ! upload_one "$FINAL_CSV" "RACHEL"; then
      log "[warn] Upload failed; queueing new RACHEL file."
      queue_one "$FINAL_CSV" "$QUEUE_DIR" "RACHEL"
    fi
  else
    queue_one "$FINAL_CSV" "$QUEUE_DIR" "RACHEL"
  fi
fi

OVERALL_FAIL=0

if kolibri_is_available; then
  if ! WINDOW_EXPORTS="$(kolibri_schedule_window "$SCHEDULE_TYPE" "$DEVICE_LOCATION" "$RUN_INTERVAL")"; then
    log "[error] Unable to resolve the Kolibri window for schedule '$SCHEDULE_TYPE'."
    OVERALL_FAIL=1
  else
    eval "$WINDOW_EXPORTS"
    KOLIBRI_FILE="$KOLIBRI_EXPORT_DIR/$WINDOW_FILENAME"

    log "[kolibri] Schedule '$SCHEDULE_TYPE' uses window: $WINDOW_LABEL"

    if kolibri_export_summary "$KOLIBRI_FILE" "$KOLIBRI_FACILITY_ID" "$WINDOW_START_DATE" "$WINDOW_END_DATE"; then
      if ! kolibri_has_data_rows "$KOLIBRI_FILE"; then
        log "[info] Kolibri summary contains only the header row; uploading it anyway to preserve the snapshot."
      fi

      if (( ONLINE )); then
        if ! upload_one "$KOLIBRI_FILE" "Kolibri"; then
          log "[warn] Kolibri upload failed; queueing the export."
          queue_one "$KOLIBRI_FILE" "$QUEUE_DIR" "Kolibri"
        fi
      else
        queue_one "$KOLIBRI_FILE" "$QUEUE_DIR" "Kolibri"
      fi
    else
      log "[error] Kolibri summary export failed."
      OVERALL_FAIL=1
    fi
  fi
else
  log "[info] Kolibri CLI not installed on this device. Skipping Kolibri summary export."
fi

if (( OVERALL_FAIL )); then
  log "[warn] Run finished with Kolibri export errors."
  exit 1
fi

log "[done] Run finished."
