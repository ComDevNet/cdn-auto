#!/bin/bash

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Read the current s3_bucket variable from upload.sh
s3_bucket=$(awk -F= '/^s3_bucket=/{print $2}' scripts/data/upload/upload.sh | tr -d '"')

# Display the current s3_bucket variable
echo "Current s3_bucket: $s3_bucket"

# Ask the user if they want to change the location
read -p "Do you want to change the s3_bucket location? (y/n): " choice

if [[ $choice == "y" || $choice == "Y" ]]; then
    # Display all the available buckets
    if ! aws s3 ls; then
        echo -e "${RED}Could not list buckets right now. You can still enter the full bucket URI manually.${NC}"
    fi

    # Ask for the new location
    while true; do
        echo ""
        echo "Enter the full s3_bucket location, e.g. s3://my-bucket-name"
        read -p "New s3_bucket location: " new_location

        if [[ -z "$new_location" ]]; then
            echo -e "${RED}s3_bucket location cannot be empty.${NC}"
            continue
        fi

        if [[ ! "$new_location" =~ ^s3://[^[:space:]]+$ ]]; then
            echo -e "${RED}Please enter the full bucket URI starting with s3://.${NC}"
            continue
        fi

        break
    done

    # Update the upload.sh file with the new location
    sudo sed -i "s|^s3_bucket=.*|s3_bucket=\"$new_location\"|" scripts/data/upload/upload.sh

    echo -e "${GREEN}s3_bucket location updated successfully.${NC} Returning to main menu..."
    sleep 1.5
    exec ./scripts/data/upload/main.sh
else
    echo -e "${RED}s3_bucket location remains unchanged.${NC} Returning to main menu..."
    sleep 1.5
    exec ./scripts/data/upload/main.sh
fi
