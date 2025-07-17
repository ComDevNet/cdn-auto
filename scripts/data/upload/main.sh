#!/bin/bash

# clear the screen
clear

echo ""
echo ""

# Display the name of the tool
figlet -c -t -f 3d "UPLOAD" | lolcat

echo ""

# A border to cover the description and its centered
echo  "=============================================================="
echo "Upload your processed Logs to AWS S3 Bucket"
echo "=============================================================="

echo ""

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
DARK_GRAY='\033[1;30m'
GREEN='\033[0;32m'

# Display menu options
echo -e "1. Upload Data           ${DARK_GRAY}-| Upload your processed Logs to AWS S3 Bucket${NC}"
echo -e "2. Configure AWS CLI     ${DARK_GRAY}-| Configure AWS CLI${NC}"
echo -e "3. Change s3 Bucket      ${DARK_GRAY}-| Change s3 Bucket URI${NC}"
echo -e "${GREEN}4. Go Back               ${DARK_GRAY}-| Go back to the main menu${NC}"
echo -e "${RED}5. Exit                  ${DARK_GRAY}-| Exit the program${NC}"

echo -e "${NC}"
# Prompt the user for input
read -p "Choose an option (1-5): " choice

# Check the user's choice and execute the corresponding script
case $choice in
    1)
        ./scripts/data/upload/upload.sh
        ;; 
    2)
        ./scripts/data/upload/configure.sh
        ;;
    3)
        ./scripts/data/upload/s3_bucket.sh
        ;;
    4)
        ./scripts/data/main.sh
        ;;
    5)
        ./exit.sh
        ;;
    *)
        echo -e "${RED}Invalid choice. Please choose a number between 1 and 5."
        echo -e "${NC}"
        sleep 1.5
        exec ./scripts/data/upload/main.sh
        ;;
esac
