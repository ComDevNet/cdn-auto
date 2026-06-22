#!/bin/bash

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/data/lib/s3_picker_helpers.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/data/lib/cleanup_helpers.sh"

CONFIG_FILE="config/automation.conf"
S3_BUCKET_DEFAULT="s3://rachel-upload-test"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi
s3_bucket="${S3_BUCKET:-$S3_BUCKET_DEFAULT}"

RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

echo "Available ModuleGaze processed folders:"
mapfile -t folders < <(find 00_DATA/00_PROCESSED/ -maxdepth 1 -type d -iname "*modulegaze*log*" | sort)

if [ ${#folders[@]} -eq 0 ]; then
    echo -e "${RED}No ModuleGaze processed folders found.${NC}"
    exit 1
fi

PS3="Please enter the number of the folder you want to select: "
select folder in "${folders[@]}"; do
    if [ -n "$folder" ]; then
        echo "You selected: $folder"
        break
    else
        echo "Invalid selection. Try again."
    fi
done

echo ""
read -rp "Please type the location of the device: " location
location=${location// /_}

while true; do
    read -rp "Please enter the starting month for filtering (1-12): " month
    if [[ "$month" =~ ^[1-9]$|^1[0-2]$ ]]; then
        month=$(printf "%02d" "$month")
        break
    else
        echo "Invalid input. Enter a number from 1 to 12."
    fi
done

processed_run_name="$(basename -- "$folder")"
PROCESSED_ROOT="$PROJECT_ROOT/00_DATA/00_PROCESSED"

summary_file="$folder/summary.csv"
summary_copy="$folder/summary_copy.csv"
if [ ! -f "$summary_file" ]; then
    echo -e "${RED}summary.csv not found in selected folder.${NC}"
    exit 1
fi
cp "$summary_file" "$summary_copy"

year=$(python3 scripts/data/upload/process_csv.py "$folder" "$location" "$month" "summary_copy.csv" "year" "modulegaze_logs")

if [ $? -ne 0 ] || [ -z "$year" ]; then
    echo -e "${RED}CSV processing failed or no ModuleGaze rows matched this period.${NC}"
    cleanup_processed_run_folder "$PROCESSED_ROOT" "$processed_run_name"
    sleep 2
    exec ./scripts/data/upload/main.sh
fi

selected_bucket="$(pick_s3_subfolder_select "$s3_bucket")" || {
  echo -e "${RED}Could not select an S3 subfolder.${NC}"
  sleep 2
  exec ./scripts/data/upload/main.sh
}

processed_filename="${location}_${month}_${year}_modulegaze_logs.csv"
processed_path="$folder/$processed_filename"
if [ -n "$selected_bucket" ]; then
    remote_path="$s3_bucket/${selected_bucket}/ModuleGaze/$processed_filename"
else
    remote_path="$s3_bucket/ModuleGaze/$processed_filename"
fi

if [ -f "$processed_path" ]; then
    echo -e "${DARK_GRAY}Uploading: $processed_path -> $remote_path${NC}"
    aws s3 cp "$processed_path" "$remote_path"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}ModuleGaze data upload completed successfully.${NC}"
        cleanup_processed_run_folder "$PROCESSED_ROOT" "$processed_run_name"
    else
        echo -e "${RED}Upload failed. Please check your AWS setup.${NC}"
    fi
else
    echo -e "${RED}Processed file not found. Something went wrong during CSV processing.${NC}"
fi

sleep 2
exec ./scripts/data/upload/main.sh
