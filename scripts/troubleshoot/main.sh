#!/bin/bash

# clear the screen
clear

echo ""
echo ""

# Display the name of the tool
figlet -t -f 3d "Troubleshoot" | lolcat

echo ""

# A border to cover the description and its centered
echo  "========================================"
echo "Check out whats wrong with your server"
echo "========================================"

echo ""

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
DARK_GRAY='\033[1;30m'
GREEN='\033[0;32m'

# Display menu options
echo -e "1. OC4D           ${DARK_GRAY}-| Check oc4d status${NC}"
echo -e "2. Kolibri         ${DARK_GRAY}-| Check kolibri status${NC}"
echo -e "3. Storage        ${DARK_GRAY}-| Check storage${NC}"
echo -e "4. Wifi           ${DARK_GRAY}-| Check hostapd${NC}"
echo -e "${GREEN}5. Go Back        ${DARK_GRAY}-| Go back to the main menu${NC}"
echo -e "${RED}6. Exit           ${DARK_GRAY}-| Exit the program${NC}"

echo -e "${NC}"
# Prompt the user for input
read -p "Choose an option (1-6): " choice

# Check the user's choice and execute the corresponding script
case $choice in
    1)
        ./scripts/troubleshoot/oc4d.sh
        ;;
    2)
        ./scripts/troubleshoot/kolibri.sh
        ;;
    3)
        ./scripts/troubleshoot/storage.sh
        ;;
    4) 
        ./scripts/troubleshoot/wifi.sh
        ;;
    5)
        ./main.sh
        ;;
    6)
        ./exit.sh
        ;;
    *)
        echo "Invalid choice. Please choose a number between 1 and 6."
        sleep 1.5
        exec ./scripts/vpn/main.sh
        ;;
esac
