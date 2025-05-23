#!/bin/bash

## This script allows you to pick what you want to update on the system

# clear the screen
clear

echo ""
echo ""

# Display the name of the tool
figlet -t -f 3d "UPDATE" | lolcat
echo ""

# A border to cover the description and its centered
echo  "================================================================"
echo "Easily update the Raspberry Pi, Rachel Interface and this Tool."
echo "================================================================"

echo ""

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Display menu options
echo -e "1. System       ${DARK_GRAY}-| Update the Raspberry Pi${NC}"
echo -e "2. Tool         ${DARK_GRAY}-| Update this tool${NC}"
echo -e "${GREEN}3. Go Back      ${DARK_GRAY}-| Go back to the main menu${NC}"
echo -e "${RED}4. Exit         ${DARK_GRAY}-| Exit the program${NC}"

echo -e "${NC}"
# Prompt the user for input
read -p "Choose an option (1-4): " choice

# Check the user's choice and execute the corresponding script
case $choice in
    1)
        ./scripts/update/system.sh
        ;;
    2)
        ./scripts/update/tool.sh
        ;;
    3)
        ./main.sh
        ;;
    4)
        ./exit.sh
        ;;
    *)
        echo "Invalid choice. Please choose a number between 1 and 4."
        sleep 1.5
        exec ./scripts/update/main.sh
        ;;
esac
