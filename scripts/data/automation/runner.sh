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
source "$PROJECT_ROOT/scripts/data/lib/oc4d_assessment_helpers.sh"
source "$PROJECT_ROOT/scripts/data/lib/cleanup_helpers.sh"

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
    log "[info] No new data in summary.csv. Skipping RACHEL upload for this run."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$NEW_FOLDER"
    return 0
  fi

  case "$SCHEDULE_TYPE" in
    hourly|daily|weekly|monthly|yearly|custom)
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
      log "[rachel][warn] Unknown SCHEDULE_TYPE '$SCHEDULE_TYPE' in config. Skipping RACHEL upload."
      return 0
      ;;
  esac

  if [[ -n "$FINAL_CSV" && -f "$FINAL_CSV" ]]; then
    file_size="$(du -h "$FINAL_CSV" | cut -f1)"
    log "[upload] Prepared $(basename "$FINAL_CSV") ($file_size)"
  else
    FINAL_CSV=""
    log "[info] No new entries matched the time period. Skipping RACHEL upload for this run."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$NEW_FOLDER"
  fi
}

process_rachel_logs

ONLINE=0
if has_internet; then
  ONLINE=1
  log "[online] Internet OK. Flushing queued uploads..."
  export CDN_AUTO_PROCESSED_ROOT="$PROCESSED_ROOT"
  flush_all_queues "$QUEUE_DIR" || log "[warn] Some queued files could not be flushed; continuing with new exports."
else
  log "[offline] No internet. New exports will be queued."
fi

if [[ -n "$FINAL_CSV" ]]; then
  if (( ONLINE )); then
    if upload_one "$FINAL_CSV" "RACHEL"; then
      cleanup_processed_run_folder "$PROCESSED_ROOT" "$NEW_FOLDER"
    else
      log "[warn] Upload failed; queueing new RACHEL file."
      queue_one "$FINAL_CSV" "$QUEUE_DIR" "RACHEL"
    fi
  else
    queue_one "$FINAL_CSV" "$QUEUE_DIR" "RACHEL"
  fi
fi

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
    log "[modulegaze][warn] ModuleGaze processing failed. Skipping ModuleGaze upload for this run."
    return 0
  fi
  cleanup_raw_run_folder "$DATA_DIR" "$modulegaze_folder"

  if [[ ! -s "$modulegaze_summary" ]]; then
    log "[modulegaze] No new data in summary.csv. Skipping ModuleGaze upload."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$modulegaze_folder"
    return 0
  fi

  log "[modulegaze][filter] Schedule '$SCHEDULE_TYPE'"
  if ! modulegaze_final_basename="$(python3 "scripts/data/automation/filter_time_based.py" "$modulegaze_processed_dir" "$DEVICE_LOCATION" "$SCHEDULE_TYPE" "$RUN_INTERVAL" "modulegaze_logs")"; then
    log "[modulegaze][warn] ModuleGaze time-window filter failed. Skipping ModuleGaze upload for this run."
    return 0
  fi
  if [[ -n "$modulegaze_final_basename" ]]; then
    modulegaze_final_csv="$modulegaze_processed_dir/$modulegaze_final_basename"
  fi

  if [[ -z "$modulegaze_final_csv" || ! -f "$modulegaze_final_csv" ]]; then
    log "[modulegaze] No entries matched the time period. Skipping ModuleGaze upload."
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$modulegaze_folder"
    return 0
  fi

  log "[modulegaze][upload] Prepared $(basename "$modulegaze_final_csv") ($(du -h "$modulegaze_final_csv" | cut -f1))"
  if (( ONLINE )); then
    if upload_one "$modulegaze_final_csv" "ModuleGaze"; then
      cleanup_processed_run_folder "$PROCESSED_ROOT" "$modulegaze_folder"
    else
      log "[modulegaze][warn] Upload failed; queueing new ModuleGaze file."
      queue_one "$modulegaze_final_csv" "$QUEUE_DIR" "ModuleGaze"
    fi
  else
    queue_one "$modulegaze_final_csv" "$QUEUE_DIR" "ModuleGaze"
  fi
}

process_modulegaze_logs

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
  local uploaded=0 skipped=0 failed=0 queued=0
  local new_uploaded_ids=()

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
    if (( ONLINE )); then
      upload_oc4d_one "$file_path" "$s3_key" || {
        queue_oc4d_one "$file_path" "$QUEUE_DIR" "$s3_key"
        queued=$((queued + 1))
        failed=$((failed + 1))
      }
    else
      queue_oc4d_one "$file_path" "$QUEUE_DIR" "$s3_key"
      queued=$((queued + 1))
    fi
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
    if (( ONLINE )); then
      if upload_oc4d_one "$csv_path" "$s3_key"; then
        uploaded=$((uploaded + 1))
      else
        queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
        queued=$((queued + 1))
        failed=$((failed + 1))
      fi
    else
      queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
      queued=$((queued + 1))
    fi
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
    if (( ONLINE )); then
      if upload_oc4d_one "$csv_path" "$s3_key"; then
        uploaded=$((uploaded + 1))
        [[ -n "$result_id" ]] && new_uploaded_ids+=("$result_id")
      else
        queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
        queued=$((queued + 1))
        failed=$((failed + 1))
      fi
    else
      queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
      queued=$((queued + 1))
    fi
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
  failed=$((failed + $(python3 - "$manifest_path" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(manifest.get("failed", [])))
PY
)))

  if (( ${#new_uploaded_ids[@]} > 0 )); then
    python3 - "$OC4D_STATE_FILE" "${new_uploaded_ids[@]}" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
ids = [item for item in sys.argv[2:] if item]
uploaded = set()
if state_path.exists():
    try:
        uploaded = set(json.loads(state_path.read_text(encoding="utf-8")).get("uploadedIds", []))
    except json.JSONDecodeError:
        uploaded = set()
uploaded.update(ids)
state_path.parent.mkdir(parents=True, exist_ok=True)
state_path.write_text(json.dumps({"uploadedIds": sorted(uploaded)}, indent=2) + "\n", encoding="utf-8")
PY
  fi

  log "[oc4d][report] uploaded=$uploaded queued=$queued skipped=$skipped failed=$failed"
  if (( failed > 0 )); then
    log "[oc4d][warn] Assessment stage finished with validation/upload failures."
  fi
  return 0
}

process_oc4d_assessments

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
