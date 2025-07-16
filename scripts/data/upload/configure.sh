#!/bin/bash

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Check if AWS CLI is already configured
if aws configure list &> /dev/null; then
    echo "AWS CLI is already configured with the following settings:"
    aws configure list
    read -p "Do you want to change the configuration? (y/n): " choice
    if [[ $choice == "y" ]]; then
        aws configure
        echo -e "${GREEN}AWS CLI configuration updated successfully.${NC} Returning to the main menu..."
        sleep 1.5
        exec ./scripts/data/upload/main.sh
    else
        echo "No changes made to the configuration."
        sleep 2
        exec ./scripts/data/upload/main.sh
    fi
else
    read -p "AWS CLI is not configured. Do you want to configure it? (y/n): " choice
    if [[ $choice == "y" ]]; then
        aws configure
    else
     echo ""
        echo "AWS CLI configuration skipped. Returning to the main menu..."
        sleep 1.5
        exec ./scripts/data/upload/main.sh
    fi
fi
