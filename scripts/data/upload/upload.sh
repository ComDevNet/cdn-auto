#!/bin/bash

s3_bucket="s3://upload-test"

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Display all folders with 'log' in their name
echo "Available folders:"
folders=(00_DATA/00_PROCESSED/*log*/)

PS3="Please enter the number of the folder you want to select: "

select folder in "${folders[@]}"; do
    if [ -n "$folder" ]; then
        echo "You selected $folder"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Ask user for the location name
echo ""
echo "Please type the location of the device:"
read location

# Replace spaces with underscores
location=${location// /_}

# Ask user for the desired month
while true; do
    read -p "Please enter the starting month for filtering (1-12): " month
    if [[ $month =~ ^[1-9]$|^1[0-2]$ ]]; then
        # Format month with two digits
        month=$(printf "%02d" "$month")
        break
    else
        echo "Invalid input. Please enter a number between 1 and 12."
    fi
done

# Create a copy of the summary.csv file
cp "$folder/summary.csv" "$folder/summary_copy.csv"

# Call Python script to process the copied CSV file and get the year
year=$(python3 scripts/data/upload/process_csv.py "$folder" "$location" "$month" "access_logs.csv")

# Display all AWS S3 buckets
echo "Available S3 buckets:"
aws s3 ls $s3_bucket/

# Ask the user to pick a bucket
echo ""
read -p "Enter the name of the S3 bucket: " selected_bucket

# Check if the processed file exists before attempting to upload
processed_filename="${location}_${month}_${year}_access_logs.csv"
if [ -e "$folder/$processed_filename" ]; then
    # Upload the new file to S3
    aws s3 cp "$folder/$processed_filename" "$s3_bucket/${selected_bucket}/RACHEL/$processed_filename"

    echo -e "${GREEN}Data upload completed successfully.${NC} Returning to main menu..."
    sleep 4
    exec ./scripts/data/upload/main.sh
else
    echo -e "${RED}The processed file does not exist or the process was not successful.${NC}"
    sleep 2
    exec ./scripts/data/upload/main.sh
fi
