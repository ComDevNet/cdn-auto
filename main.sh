#!/bin/bash

# clear the screen
clear

# Change directory to the script's location
cd "$(dirname "$(readlink -f "$0")")"

echo ""
echo ""

# Display the name of the tool
figlet -t -f 3d "CDN  AUTO" | lolcat
echo ""

echo  "==================================================================================================="
echo "Automate actions on the servers, this tool is brought to you by Community Development Network (CDN)"
echo "==================================================================================================="

echo ""
echo "Available Tools:"
echo ""

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
GRAY='\033[1;30m'

# Display menu options
echo -e "1. Update        ${GRAY}-| Update the Raspberry pi, and Programs${NC}"
echo -e "2. VPN           ${GRAY}-| Install and configure the Zero-tier VPN${NC}"
echo -e "3. Data          ${GRAY}-| Collect, Process and Upload logs${NC}"
echo -e "4. System        ${GRAY}-| Change system settings${NC}"
echo -e "5. Troubleshoot  ${GRAY}-| Find out what's wrong with your server${NC}"
echo -e "6. Database      ${GRAY}-| Backup and restore the OC4D database${NC}"
echo -e "${RED}7. Exit          ${GRAY}-| Exit CDN Auto${NC}"

echo -e "${NC}"
# Prompt the user for input
read -p "Choose an option (1-7): " choice

# Check the user's choice and execute the corresponding script
case $choice in
    1)
        ./scripts/update/main.sh
        ;;
    2)
        ./scripts/vpn/main.sh
        ;;
    3)
        ./scripts/data/main.sh
        ;;
    4)
        ./scripts/system/main.sh
        ;;
    5)
        ./scripts/troubleshoot/main.sh
        ;;
    6)
        ./scripts/database/main.sh
        ;;
    7)
        ./exit.sh
        ;;
    *)
        echo -e "${RED}Invalid choice. Please choose a number between 1 and 7.${NC}. Restarting..."
        sleep 3
        exec ./main.sh
        ;;
esac
