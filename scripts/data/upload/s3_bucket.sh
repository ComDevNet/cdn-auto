#!/bin/bash

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Read the current s3_bucket variable from upload.sh
s3_bucket=$(grep -oP '(?<=s3_bucket=).+' scripts/data/upload/upload.sh)

# Display the current s3_bucket variable
echo "Current s3_bucket: $s3_bucket"

# Ask the user if they want to change the location
read -p "Do you want to change the s3_bucket location? (y/n): " choice

if [[ $choice == "y" || $choice == "Y" ]]; then
    # Display all the available buckets
    aws s3 ls

    # Ask for the new location
    echo ""
    echo "Enter the full s3_bucket location, e.g. s3://my-bucket-name"
    read -p "New s3_bucket location: " new_location

    # Update the upload.sh file with the new location
    sudo sed -i "s|s3_bucket=.*|s3_bucket=$new_location|" scripts/data/upload/upload.sh

    echo -e "${GREEN}s3_bucket location updated successfully.${NC} Returning to main menu..."
    sleep 1.5
    exec ./scripts/data/upload/main.sh
else
    echo -e "${RED}s3_bucket location remains unchanged.${NC} Returning to main menu..."
    sleep 1.5
    exec ./scripts/data/upload/main.sh
fi
