#!/bin/bash

s3_bucket="s3://upload-test"

# Terminal colors
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# List available folders
echo "Available folders:"
mapfile -t folders < <(find 00_DATA/00_PROCESSED/ -maxdepth 1 -type d -iname "*log*" | sort)

if [ ${#folders[@]} -eq 0 ]; then
    echo -e "${RED}No folders matching '*log*' found.${NC}"
    exit 1
fi

# Prompt user to select a folder
PS3="Please enter the number of the folder you want to select: "
select folder in "${folders[@]}"; do
    if [ -n "$folder" ]; then
        echo "You selected: $folder"
        break
    else
        echo "Invalid selection. Try again."
    fi
done

# Ask for device location
echo ""
read -rp "Please type the location of the device: " location
location=${location// /_}  # Replace spaces with underscores

# Ask for the filtering month
while true; do
    read -rp "Please enter the starting month for filtering (1–12): " month
    if [[ "$month" =~ ^[1-9]$|^1[0-2]$ ]]; then
        month=$(printf "%02d" "$month")  # Always two digits
        break
    else
        echo "Invalid input. Enter a number from 1 to 12."
    fi
done

# Efficiently copy file only if it exists
summary_file="$folder/summary.csv"
summary_copy="$folder/summary_copy.csv"
if [ ! -f "$summary_file" ]; then
    echo -e "${RED}summary.csv not found in selected folder.${NC}"
    exit 1
fi
cp "$summary_file" "$summary_copy"

# Run Python processor and capture year
year=$(python3 scripts/data/upload/process_csv.py "$folder" "$location" "$month" "summary_copy.csv")

# Exit if processing failed
if [ $? -ne 0 ] || [ -z "$year" ]; then
    echo -e "${RED}CSV processing failed. Please check your data.${NC}"
    sleep 2
    exec ./scripts/data/upload/main.sh
fi

# Prompt for bucket subfolder
echo ""
aws s3 ls "$s3_bucket/"
read -rp "Enter the name of the S3 subfolder: " selected_bucket

# Construct processed filename
processed_filename="${location}_${month}_${year}_access_logs.csv"
processed_path="$folder/$processed_filename"

if [ -f "$processed_path" ]; then
    echo -e "${DARK_GRAY}Uploading: $processed_path → $s3_bucket/${selected_bucket}/RACHEL/${processed_filename}${NC}"
    aws s3 cp "$processed_path" "$s3_bucket/${selected_bucket}/RACHEL/$processed_filename"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Data upload completed successfully.${NC}"
    else
        echo -e "${RED}Upload failed. Please check your AWS setup.${NC}"
    fi
else
    echo -e "${RED}Processed file not found. Something went wrong during CSV processing.${NC}"
fi

# Return to main menu
sleep 2
exec ./scripts/data/upload/main.sh
