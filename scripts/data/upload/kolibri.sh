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

EXPORT_DIR="$PROJECT_ROOT/00_DATA/00_KOLIBRI_EXPORTS"
QUEUE_DIR="$PROJECT_ROOT/00_DATA/00_UPLOAD_QUEUE"
mkdir -p "$EXPORT_DIR"
prepare_queue_dirs "$QUEUE_DIR"

OUTPUT_FILE="$EXPORT_DIR/$(kolibri_export_filename "$DEVICE_LOCATION")"

if ! kolibri_export_summary "$OUTPUT_FILE" "$KOLIBRI_FACILITY_ID"; then
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
