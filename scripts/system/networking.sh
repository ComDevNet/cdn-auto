#!/bin/bash

# clear the screen
clear

echo ""
echo ""

# Display the name of the tool
figlet -c -t -f 3d "Networking" | lolcat

echo ""

# A border to cover the description and its centered
echo  "================================================================================="
echo "Get the the current IP addresses and monitor changes"
echo "================================================================================="

echo ""

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Display menu options
echo -e "1. Run Monitor                       ${DARK_GRAY}-| Run the script which monitors and updates IP addresses${NC}"
echo -e "2. Display IP Addresses              ${DARK_GRAY}-| Show the current IP addresses${NC}"
echo -e "${GREEN}3. Go Back                           ${DARK_GRAY}-| Go back to the main menu${NC}"
echo -e "${RED}4. Exit                              ${DARK_GRAY}-| Exit the program${NC}"

echo -e "${NC}"
# Prompt the user for input
read -p "Choose an option (1-4): " choice

# Check the user's choice and execute the corresponding script
case $choice in
    1)
        ./scripts/system/networking/run_monitor.sh
        ;;
    2) 
        ./scripts/system/networking/check_ip.sh
        ;;
    3) 
        ./main.sh
        ;;
    4)
        ./exit.sh
        ;;
    *)
        echo -e "${RED}Invalid choice. Please choose a number between 1 and 4.${NC}"
        sleep 1.5
        exec ./scripts/system/networking.sh
        ;;
esac
