#!/bin/bash
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/data/lib/s3_helpers.sh"
source "$PROJECT_ROOT/scripts/data/lib/kolibri_helpers.sh"

CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

clear
echo ""
echo ""

figlet -c -t -f 3d "KOLIBRI" | lolcat

echo ""
echo "=============================================================="
echo "Export the Kolibri summary CSV and upload it to AWS S3"
echo "=============================================================="
echo ""

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  log "[config] Loaded automation config from $CONFIG_FILE"
fi

S3_BUCKET="${S3_BUCKET:-}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
DEVICE_LOCATION="${DEVICE_LOCATION:-kolibri}"
KOLIBRI_FACILITY_ID="${KOLIBRI_FACILITY_ID:-}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"

if ! kolibri_is_available; then
  log "[error] Kolibri CLI is not installed on this device."
  sleep 3
  exec ./scripts/data/upload/main.sh
fi

if [[ -n "$S3_BUCKET" ]]; then
  echo "Current destination:"
  echo "  ${S3_BUCKET%/}/${S3_SUBFOLDER:+$S3_SUBFOLDER/}Kolibri/"
  echo ""
  read -rp "Use this destination? (Y/n): " use_existing
  if [[ "${use_existing,,}" == "n" || "${use_existing,,}" == "no" ]]; then
    S3_BUCKET=""
  fi
fi

while [[ -z "$S3_BUCKET" ]]; do
  read -rp "Enter the S3 bucket to use (for example s3://oc4d-raw-reports): " S3_BUCKET
  S3_BUCKET="${S3_BUCKET%/}"
  if [[ ! "$S3_BUCKET" =~ ^s3:// ]]; then
    echo "Bucket must start with s3://"
    S3_BUCKET=""
  fi
done

read -rp "Enter the S3 subfolder to use [${S3_SUBFOLDER:-root}]: " selected_subfolder
if [[ -n "${selected_subfolder:-}" ]]; then
  S3_SUBFOLDER="${selected_subfolder#/}"
  S3_SUBFOLDER="${S3_SUBFOLDER%/}"
fi

read -rp "Device/location label [${DEVICE_LOCATION}]: " selected_location
if [[ -n "${selected_location:-}" ]]; then
  DEVICE_LOCATION="${selected_location// /_}"
fi

resolve_preset_window() {
  local selected_schedule_type="$1"
  local selected_run_interval="${2:-$RUN_INTERVAL}"

  if ! WINDOW_EXPORTS="$(kolibri_schedule_window "$selected_schedule_type" "$DEVICE_LOCATION" "$selected_run_interval")"; then
    log "[error] Unable to resolve the Kolibri window for schedule '$selected_schedule_type'."
    sleep 3
    exec ./scripts/data/upload/main.sh
  fi

  eval "$WINDOW_EXPORTS"
}

resolve_custom_date_window() {
  local start_date=""
  local end_date=""

  while :; do
    read -rp "Enter the start date (YYYY-MM-DD): " start_date
    if kolibri_is_valid_date "$start_date"; then
      start_date="$(date -d "$start_date" '+%Y-%m-%d')"
      break
    fi
    echo "Please enter a valid start date in YYYY-MM-DD format."
  done

  while :; do
    read -rp "Enter the end date (YYYY-MM-DD): " end_date
    if ! kolibri_is_valid_date "$end_date"; then
      echo "Please enter a valid end date in YYYY-MM-DD format."
      continue
    fi

    end_date="$(date -d "$end_date" '+%Y-%m-%d')"
    if [[ "$start_date" > "$end_date" ]]; then
      echo "End date must be the same as or later than the start date."
      continue
    fi
    break
  done

  WINDOW_START_DATE="${start_date}T00:00:00"
  WINDOW_END_DATE="${end_date}T23:59:59"
  WINDOW_LABEL="${start_date} to ${end_date}"
  WINDOW_FILENAME="$(kolibri_manual_range_filename "$DEVICE_LOCATION" "$start_date" "$end_date")"
  WINDOW_SCHEDULE_TYPE="manual"
}

echo "Choose the export range:"
echo "  1. Use automation schedule (${SCHEDULE_TYPE})"
echo "  2. Hourly (last completed hour)"
echo "  3. Daily (yesterday)"
echo "  4. Weekly (last completed week)"
echo "  5. Monthly (last completed month)"
echo "  6. Yearly (last completed year)"
echo "  7. Custom start and end dates"
echo "  8. Go back"

while :; do
  read -rp "Choose an option (1-8): " range_choice
  case "$range_choice" in
    1)
      resolve_preset_window "$SCHEDULE_TYPE" "$RUN_INTERVAL"
      break
      ;;
    2)
      resolve_preset_window "hourly" "3600"
      break
      ;;
    3)
      resolve_preset_window "daily" "86400"
      break
      ;;
    4)
      resolve_preset_window "weekly" "604800"
      break
      ;;
    5)
      resolve_preset_window "monthly" "2592000"
      break
      ;;
    6)
      resolve_preset_window "yearly" "31536000"
      break
      ;;
    7)
      resolve_custom_date_window
      break
      ;;
    8)
      exec ./scripts/data/upload/main.sh
      ;;
    *)
      echo "Please choose a number between 1 and 8."
      ;;
  esac
done

EXPORT_DIR="$PROJECT_ROOT/00_DATA/00_KOLIBRI_EXPORTS"
QUEUE_DIR="$PROJECT_ROOT/00_DATA/00_UPLOAD_QUEUE"
mkdir -p "$EXPORT_DIR"
prepare_queue_dirs "$QUEUE_DIR"

OUTPUT_FILE="$EXPORT_DIR/$WINDOW_FILENAME"

log "[kolibri] Using range: $WINDOW_LABEL"

if ! kolibri_export_summary "$OUTPUT_FILE" "$KOLIBRI_FACILITY_ID" "$WINDOW_START_DATE" "$WINDOW_END_DATE"; then
  log "[error] Kolibri summary export failed."
  sleep 3
  exec ./scripts/data/upload/main.sh
fi

if ! kolibri_has_data_rows "$OUTPUT_FILE"; then
  log "[info] The export only contains the header row, but it will still be uploaded as a valid snapshot."
fi

if upload_one "$OUTPUT_FILE" "Kolibri"; then
  log "[done] Kolibri summary uploaded successfully."
else
  log "[warn] Upload failed. Queueing the export for the next automation flush."
  queue_one "$OUTPUT_FILE" "$QUEUE_DIR" "Kolibri"
fi

sleep 2
exec ./scripts/data/upload/main.sh
