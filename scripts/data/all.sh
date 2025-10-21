#!/bin/bash

YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Clear the screen
clear

echo ""

echo -e "${YELLOW}Choose an option:${NC}"
echo "1. V1 - Server v4"
echo "2. V2 - Server v5"
echo "3. V3 - Server v6"
echo "4. V4 - D-Hub"
echo ""

# Prompt user for their choice
read -p "Enter your choice (1, 2, 3, or 4): " user_choice

# Handle user input
if [[ "$user_choice" == "1" ]]; then
    echo -e "${YELLOW}Starting Data Collection and Processing (V1) in 2 seconds...${NC}"
    sleep 2
    exec ./scripts/data/all/v1/collection.sh
elif [[ "$user_choice" == "2" ]]; then
    echo -e "${YELLOW}Starting Data Collection and Processing (V2) in 2 seconds...${NC}"
    sleep 2
    exec ./scripts/data/all/v2/collection.sh
elif [[ "$user_choice" == "3" ]]; then
    echo -e "${YELLOW}Starting Data Collection and Processing (V3 - Server v6) in 2 seconds...${NC}"
    sleep 2
    exec ./scripts/data/all/v3/collection.sh
elif [[ "$user_choice" == "4" ]]; then
    echo -e "${YELLOW}Starting Data Collection and Processing (V4 - D-Hub) in 2 seconds...${NC}"
    sleep 2
    exec ./scripts/data/all/v4/collection.sh
else
    echo -e "${RED}Invalid choice. Please select 1, 2, 3, or 4.${NC}"
    echo -e "${YELLOW}Returning to the main menu...${NC}"
    sleep 2
    exec ./scripts/data/main.sh
fi
