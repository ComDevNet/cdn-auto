#!/bin/bash

# clear the screen
clear

echo ""
echo ""

# Display the name of the tool
figlet -t -f 3d "DATA" | lolcat

echo ""

# A border to cover the description and its centered
echo  "=============================================================="
echo "Collect, Process, and Upload all the server data"
echo "=============================================================="

echo ""

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
DARK_GRAY='\033[1;30m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'

# Display menu options
echo -e "1. Start            ${DARK_GRAY}-| Collect, Process, and Upload at once${NC}"
echo -e "2. Collect          ${DARK_GRAY}-| Collect your server logs${NC}"
echo -e "3. Process          ${DARK_GRAY}-| Process your server logs${NC}"
echo -e "4. Upload           ${DARK_GRAY}-| Upload your server logs to an AWS s3 Bucket${NC}"
echo -e "5. Automation       ${DARK_GRAY}-| Configure the automated log processor${NC}"
echo -e "${GREEN}6. Go Back          ${DARK_GRAY}-| Go back to the main menu${NC}"
echo -e "${RED}7. Exit             ${DARK_GRAY}-| Exit the program${NC}"

echo -e "${NC}"
# Prompt the user for input
read -p "Choose an option (1-7): " choice

# Check the user's choice and execute the corresponding script
case $choice in
    1)
        ./scripts/data/all.sh
        ;; 
    2)
        ./scripts/data/collection/main.sh
        ;;
    3)
        ./scripts/data/process/main.sh
        ;;
    4)
        ./scripts/data/upload/main.sh
        ;;
    5)
        ./scripts/data/automation/main.sh 
        ;;
    6)
        ./main.sh
        ;;
    7)
        ./exit.sh
        ;;
    *)
        echo -e "${RED}Invalid choice. Please choose a number between 1 and 7."
        echo -e "${NC}"
        sleep 1.5
        exec ./scripts/data/main.sh
        ;;
esac