#!/bin/bash
# Runner: harvest (collect→process→filter→enqueue) and/or dispatch (windowed S3 flush).
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

# Windows edits leave CRLF; bash then dies on $'\r' while sourcing helpers.
find "$PROJECT_ROOT/scripts" -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true

source "$PROJECT_ROOT/scripts/data/lib/s3_helpers.sh"
source "$PROJECT_ROOT/scripts/data/lib/oc4d_assessment_helpers.sh"

CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"
# harvest | dispatch | all (default harvest for new timers)
RUN_MODE="${1:-${CDN_AUTO_MODE:-harvest}}"

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
HARVEST_INTERVAL="${HARVEST_INTERVAL:-3600}"
# Default daily devices to a 1h midnight window; near_realtime / others upload whenever dispatcher runs.
UPLOAD_WINDOW="${UPLOAD_WINDOW:-}"
if [[ -z "$UPLOAD_WINDOW" ]]; then
  if [[ "$SCHEDULE_TYPE" == "near_realtime" || "$SCHEDULE_TYPE" == "rolling" ]]; then
    UPLOAD_WINDOW="always"
  elif [[ "$SCHEDULE_TYPE" == "daily" ]]; then
    UPLOAD_WINDOW="00:00-01:00"
  else
    UPLOAD_WINDOW="always"
  fi
fi
MODULEGAZE_ENABLED="${MODULEGAZE_ENABLED:-1}"
MODULEGAZE_API_BASE_URL="${MODULEGAZE_API_BASE_URL:-http://127.0.0.1:3002}"
MODULEGAZE_MODULE_MAP_FILE="${MODULEGAZE_MODULE_MAP_FILE:-$PROJECT_ROOT/config/oc4d/module-map.csv}"
OC4D_ASSESSMENTS_ENABLED="${OC4D_ASSESSMENTS_ENABLED:-0}"
OC4D_API_BASE_URL="${OC4D_API_BASE_URL:-http://127.0.0.1:3000}"
OC4D_API_TOKEN="${OC4D_API_TOKEN:-}"
OC4D_BUCKET="${OC4D_BUCKET:-oc4d-raw-reports}"
OC4D_PARENT_ORG="${OC4D_PARENT_ORG:-Home-Schooling}"
OC4D_UPLOAD_MODE="${OC4D_UPLOAD_MODE:-direct_s3}"
OC4D_SOURCE_DIR="${OC4D_SOURCE_DIR:-}"
OC4D_STUDENT_MAP_FILE="${OC4D_STUDENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/student-map.csv}"
OC4D_ASSESSMENT_MAP_FILE="${OC4D_ASSESSMENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/assessment-map.csv}"
OC4D_STATE_FILE="${OC4D_STATE_FILE:-$PROJECT_ROOT/00_DATA/00_OC4D_ASSESSMENTS/uploaded-state.json}"
OC4D_UNASSIGNED_STUDENT_ID="${OC4D_UNASSIGNED_STUDENT_ID:-unassigned}"
OC4D_STUDENT_PREFIX_SYNC="${OC4D_STUDENT_PREFIX_SYNC:-1}"
OC4D_CLOUD_STUDENT_MAP_FILE="${OC4D_CLOUD_STUDENT_MAP_FILE:-}"
OC4D_CLOUD_STUDENT_MAP_S3_URI="${OC4D_CLOUD_STUDENT_MAP_S3_URI:-}"
OC4D_CLOUD_STUDENT_MAP_URL="${OC4D_CLOUD_STUDENT_MAP_URL:-}"
OC4D_CLOUD_STUDENTS_API_BASE_URL="${OC4D_CLOUD_STUDENTS_API_BASE_URL:-}"
OC4D_CLOUD_API_TOKEN="${OC4D_CLOUD_API_TOKEN:-}"

DATA_DIR="$PROJECT_ROOT/00_DATA"
PROCESSED_ROOT="$DATA_DIR/00_PROCESSED"
QUEUE_DIR="$DATA_DIR/00_UPLOAD_QUEUE"
mkdir -p "$DATA_DIR" "$PROCESSED_ROOT" "$QUEUE_DIR"
prepare_queue_dirs "$QUEUE_DIR"
export CDN_AUTO_PROCESSED_ROOT="$PROCESSED_ROOT"
export UPLOAD_WINDOW

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

FINAL_CSV=""

process_rachel_logs() {
  local log_dir=""
  local processor=""
  local processed_dir="$PROCESSED_ROOT/$NEW_FOLDER"
  local summary="$processed_dir/summary.csv"
  local final_csv_basename=""
  local file_size=""

  log "[collect] $COLLECT_DIR  (server=$SERVER_VERSION, device=$DEVICE_LOCATION)"
  mkdir -p "$COLLECT_DIR"
  case "$SERVER_VERSION" in
    v1|server\ v4|v4)
      log_dir="/var/log/apache2"
      [[ -d "$log_dir" ]] || { log "[rachel][warn] $log_dir not found. Skipping RACHEL."; return 0; }
      find "$log_dir" -type f -name 'access.log*' -exec cp {} "$COLLECT_DIR"/ \; || {
        log "[rachel][warn] RACHEL collection failed from $log_dir."
        return 0
      }
      ;;
    v2|server\ v5|v5)
      log_dir="/var/log/oc4d"
      [[ -d "$log_dir" ]] || { log "[rachel][warn] $log_dir not found. Skipping RACHEL."; return 0; }
      find "$log_dir" -type f \( \
         \( -name 'oc4d-*.log' ! -name 'oc4d-exceptions-*.log' \) -o \
         \( -name 'capecoastcastle-*.log' ! -name 'capecoastcastle-exceptions-*.log' \) -o \
         -name '*.gz' \) -exec cp {} "$COLLECT_DIR"/ \; || {
        log "[rachel][warn] RACHEL collection failed from $log_dir."
        return 0
      }
      ;;
    v3|dhub|d-hub)
      log_dir="/var/log/dhub"
      [[ -d "$log_dir" ]] || { log "[rachel][warn] $log_dir not found. Skipping RACHEL."; return 0; }
      find "$log_dir" -type f -name '*.log' -exec cp {} "$COLLECT_DIR"/ \; || {
        log "[rachel][warn] RACHEL collection failed from $log_dir."
        return 0
      }
      ;;
    server\ v6|v6)
      log_dir="/var/log/oc4d"
      [[ -d "$log_dir" ]] || { log "[rachel][warn] $log_dir not found. Skipping RACHEL."; return 0; }
      find "$log_dir" -type f -name 'oc4d-*.log' ! -name 'oc4d-exceptions-*.log' -exec cp {} "$COLLECT_DIR"/ \; || {
        log "[rachel][warn] RACHEL collection failed from $log_dir."
        return 0
      }
      ;;
    *)
      log "[rachel][warn] Unknown SERVER_VERSION '$SERVER_VERSION'. Skipping RACHEL."
      return 0
      ;;
  esac

  shopt -s nullglob
  for gz in "$COLLECT_DIR"/*.gz; do
    gzip -df "$gz" || true
  done
  shopt -u nullglob

  case "$SERVER_VERSION" in
    v1|v4)
      processor="scripts/data/process/processors/log.py"
      ;;
    v2|v5|server\ v5)
      case "$PYTHON_SCRIPT" in
        oc4d) processor="scripts/data/process/processors/logv2.py" ;;
        cape_coast_d) processor="scripts/data/process/processors/castle.py" ;;
        *) processor="scripts/data/process/processors/logv2.py" ;;
      esac
      ;;
    v3|dhub|d-hub)
      processor="scripts/data/process/processors/dhub.py"
      ;;
    server\ v6|v6)
      processor="scripts/data/process/processors/log-v6.py"
      ;;
  esac

  if [[ -z "$processor" ]]; then
    log "[rachel][warn] No processor selected for SERVER_VERSION='$SERVER_VERSION'. Skipping RACHEL."
    return 0
  fi

  log "[process] $processor  (folder=$NEW_FOLDER)"
  if ! python3 "$processor" "$NEW_FOLDER"; then
    log "[rachel][warn] RACHEL processor failed. Continuing with other data stages."
    return 0
  fi
  cleanup_raw_run_folder "$DATA_DIR" "$NEW_FOLDER"

  if [[ ! -s "$summary" ]]; then
    log "[info] No new data in summary.csv. Skipping RACHEL enqueue for this run."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$NEW_FOLDER"
    return 0
  fi

  case "$SCHEDULE_TYPE" in
    hourly|daily|weekly|monthly|yearly|custom|near_realtime|rolling)
      log "[filter] Schedule '$SCHEDULE_TYPE'"
      if ! final_csv_basename="$(python3 "scripts/data/automation/filter_time_based.py" "$processed_dir" "$DEVICE_LOCATION" "$SCHEDULE_TYPE" "$RUN_INTERVAL")"; then
        log "[rachel][warn] RACHEL time-window filter failed. Continuing with other data stages."
        return 0
      fi
      if [[ -n "$final_csv_basename" ]]; then
        FINAL_CSV="$processed_dir/$final_csv_basename"
      fi
      ;;
    *)
      log "[rachel][warn] Unknown SCHEDULE_TYPE '$SCHEDULE_TYPE' in config. Skipping RACHEL enqueue."
      return 0
      ;;
  esac

  if [[ -n "$FINAL_CSV" && -f "$FINAL_CSV" ]]; then
    file_size="$(du -h "$FINAL_CSV" | cut -f1)"
    log "[enqueue] Prepared $(basename "$FINAL_CSV") ($file_size)"
  else
    FINAL_CSV=""
    log "[info] No new entries matched the time period. Skipping RACHEL enqueue for this run."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$NEW_FOLDER"
  fi
}

process_modulegaze_logs() {
  if [[ "$MODULEGAZE_ENABLED" != "1" ]]; then
    log "[modulegaze] Disabled in config. Skipping."
    return 0
  fi

  local log_dir="/var/log/modulegaze"
  if [[ ! -d "$log_dir" ]]; then
    log "[modulegaze] $log_dir not found. Skipping."
    return 0
  fi

  local modulegaze_folder="${DEVICE_LOCATION}_modulegaze_logs_${TODAY_YMD}"
  local modulegaze_collect_dir="$DATA_DIR/$modulegaze_folder"
  local modulegaze_processed_dir="$PROCESSED_ROOT/$modulegaze_folder"
  local modulegaze_summary="$modulegaze_processed_dir/summary.csv"
  local modulegaze_final_csv=""
  local modulegaze_final_basename=""

  log "[modulegaze][collect] $modulegaze_collect_dir"
  mkdir -p "$modulegaze_collect_dir"
  find "$modulegaze_collect_dir" -maxdepth 1 -type f \( \
    -name 'modulegaze-access*' -o \
    -name 'modulegaze-sessions*' \
  \) -delete || log "[modulegaze][warn] Could not clear old collected ModuleGaze files."
  find "$log_dir" -type f \( \
    -name 'modulegaze-sessions.log' -o \
    -name 'modulegaze-sessions-*.log.zip' \
  \) -exec cp {} "$modulegaze_collect_dir"/ \; || {
    log "[modulegaze][warn] ModuleGaze collection failed from $log_dir."
    return 0
  }

  if ! find "$modulegaze_collect_dir" -type f | grep -q .; then
    log "[modulegaze] No ModuleGaze log files found. Skipping."
    return 0
  fi

  log "[modulegaze][process] scripts/data/process/processors/modulegaze.py (folder=$modulegaze_folder)"
  if ! MODULEGAZE_API_BASE_URL="$MODULEGAZE_API_BASE_URL" \
    MODULEGAZE_MODULE_MAP_FILE="$MODULEGAZE_MODULE_MAP_FILE" \
    python3 "scripts/data/process/processors/modulegaze.py" "$modulegaze_folder"; then
    log "[modulegaze][warn] ModuleGaze processing failed. Skipping ModuleGaze enqueue for this run."
    return 0
  fi
  cleanup_raw_run_folder "$DATA_DIR" "$modulegaze_folder"

  if [[ ! -s "$modulegaze_summary" ]]; then
    log "[modulegaze] No new data in summary.csv. Skipping ModuleGaze enqueue."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$modulegaze_folder"
    return 0
  fi

  log "[modulegaze][filter] Schedule '$SCHEDULE_TYPE'"
  if ! modulegaze_final_basename="$(python3 "scripts/data/automation/filter_time_based.py" "$modulegaze_processed_dir" "$DEVICE_LOCATION" "$SCHEDULE_TYPE" "$RUN_INTERVAL" "modulegaze_logs")"; then
    log "[modulegaze][warn] ModuleGaze time-window filter failed. Skipping ModuleGaze enqueue for this run."
    return 0
  fi
  if [[ -n "$modulegaze_final_basename" ]]; then
    modulegaze_final_csv="$modulegaze_processed_dir/$modulegaze_final_basename"
  fi

  if [[ -z "$modulegaze_final_csv" || ! -f "$modulegaze_final_csv" ]]; then
    log "[modulegaze] No entries matched the time period. Skipping ModuleGaze enqueue."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$modulegaze_folder"
    return 0
  fi

  log "[modulegaze][enqueue] Prepared $(basename "$modulegaze_final_csv") ($(du -h "$modulegaze_final_csv" | cut -f1))"
  queue_one "$modulegaze_final_csv" "$QUEUE_DIR" "ModuleGaze" "$modulegaze_folder"
}

process_oc4d_assessments() {
  if ! oc4d_assessments_enabled; then
    log "[oc4d] Disabled in config. Skipping."
    return 0
  fi

  if [[ "${OC4D_UPLOAD_MODE:-direct_s3}" != "direct_s3" ]]; then
    log "[oc4d][warn] Upload mode '${OC4D_UPLOAD_MODE}' is not implemented yet; using direct_s3."
  fi

  local assessments_root="$DATA_DIR/00_OC4D_ASSESSMENTS"
  local manifest_path=""
  local processor_rc=0
  local queued=0 skipped=0 failed=0

  mkdir -p "$assessments_root"
  log "[oc4d][process] scripts/data/process/processors/assessment.py"
  OC4D_API_BASE_URL="$OC4D_API_BASE_URL" \
  OC4D_API_TOKEN="$OC4D_API_TOKEN" \
  OC4D_BUCKET="$OC4D_BUCKET" \
  OC4D_PARENT_ORG="$OC4D_PARENT_ORG" \
  OC4D_SOURCE_DIR="$OC4D_SOURCE_DIR" \
  OC4D_STUDENT_MAP_FILE="$OC4D_STUDENT_MAP_FILE" \
  OC4D_ASSESSMENT_MAP_FILE="$OC4D_ASSESSMENT_MAP_FILE" \
  OC4D_STATE_FILE="$OC4D_STATE_FILE" \
  OC4D_UNASSIGNED_STUDENT_ID="$OC4D_UNASSIGNED_STUDENT_ID" \
  OC4D_STUDENT_PREFIX_SYNC="$OC4D_STUDENT_PREFIX_SYNC" \
  OC4D_CLOUD_STUDENT_MAP_FILE="$OC4D_CLOUD_STUDENT_MAP_FILE" \
  OC4D_CLOUD_STUDENT_MAP_S3_URI="$OC4D_CLOUD_STUDENT_MAP_S3_URI" \
  OC4D_CLOUD_STUDENT_MAP_URL="$OC4D_CLOUD_STUDENT_MAP_URL" \
  OC4D_CLOUD_STUDENTS_API_BASE_URL="$OC4D_CLOUD_STUDENTS_API_BASE_URL" \
  OC4D_CLOUD_API_TOKEN="$OC4D_CLOUD_API_TOKEN" \
    python3 "scripts/data/process/processors/assessment.py" || processor_rc=$?

  manifest_path="$(find "$assessments_root" -maxdepth 2 -type f -name 'manifest.json' | sort | tail -n1)"
  if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
    if (( processor_rc != 0 )); then
      log "[oc4d][warn] Assessment processor failed and no manifest was produced."
    else
      log "[oc4d] No assessment manifest produced for this run."
    fi
    return 0
  fi

  while IFS=$'\t' read -r file_path s3_key _scheme_id; do
    [[ -n "$file_path" && -f "$file_path" ]] || continue
    queue_oc4d_one "$file_path" "$QUEUE_DIR" "$s3_key"
    queued=$((queued + 1))
  done < <(
    python3 - "$manifest_path" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in manifest.get("marking_schemes", []):
    subject_json = entry.get("subject_json", "")
    subject_s3_key = entry.get("subject_s3_key", "")
    if subject_json and subject_s3_key:
        print("\t".join([subject_json, subject_s3_key, ""]))
PY
  )

  while IFS=$'\t' read -r csv_path s3_key _scheme_id; do
    [[ -n "$csv_path" && -f "$csv_path" ]] || continue
    queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
    queued=$((queued + 1))
  done < <(
    python3 - "$manifest_path" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in manifest.get("marking_schemes", []):
    print("\t".join([entry.get("csv", ""), entry.get("s3_key", ""), ""]))
PY
  )

  while IFS=$'\t' read -r csv_path s3_key result_id; do
    [[ -n "$csv_path" && -f "$csv_path" ]] || continue
    queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key" "$result_id"
    queued=$((queued + 1))
  done < <(
    python3 - "$manifest_path" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in manifest.get("ready", []):
    print(
        "\t".join(
            [
                entry.get("csv", ""),
                entry.get("s3_key", ""),
                entry.get("result_id", ""),
            ]
        )
    )
PY
  )

  skipped="$(python3 - "$manifest_path" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(manifest.get("skipped", [])))
PY
)"
  failed="$(python3 - "$manifest_path" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(manifest.get("failed", [])))
PY
)"

  log "[oc4d][report] queued=$queued skipped=$skipped failed=$failed"
  if (( failed > 0 )); then
    log "[oc4d][warn] Assessment stage finished with validation failures."
  fi
  return 0
}

run_harvest() {
  log "[mode] harvest (interval hint=${HARVEST_INTERVAL}s, filter=$SCHEDULE_TYPE)"
  process_rachel_logs
  if [[ -n "$FINAL_CSV" ]]; then
    queue_one "$FINAL_CSV" "$QUEUE_DIR" "RACHEL" "$NEW_FOLDER"
  fi
  process_modulegaze_logs
  process_oc4d_assessments
  write_queue_marker "$QUEUE_DIR" "last_harvest_ok"
  log "[harvest] Done. Pending RACHEL=$(count_queue_state "$QUEUE_DIR" RACHEL pending) ModuleGaze=$(count_queue_state "$QUEUE_DIR" ModuleGaze pending) OC4D=$(count_queue_state "$QUEUE_DIR" OC4DAssessments pending)"
}

run_dispatch() {
  log "[mode] dispatch (upload_window=$UPLOAD_WINDOW)"
  if ! upload_window_open; then
    log "[dispatch] $(next_upload_window_hint); not uploading."
    return 0
  fi
  if ! has_internet; then
    log "[dispatch] Offline; leaving pending items queued."
    return 0
  fi
  log "[dispatch] Window open and online; flushing pending uploads..."
  flush_all_queues "$QUEUE_DIR" || log "[warn] Some queued files could not be flushed."
}

case "$RUN_MODE" in
  harvest)
    run_harvest
    ;;
  dispatch)
    run_dispatch
    ;;
  all|legacy)
    run_harvest
    run_dispatch
    ;;
  *)
    log "[error] Unknown mode '$RUN_MODE' (use harvest|dispatch|all)"
    exit 2
    ;;
esac

log "[done] Run finished (mode=$RUN_MODE)."
