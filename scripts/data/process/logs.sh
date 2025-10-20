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
    echo -e "${YELLOW}Starting Data Processing (V1) in 2 seconds...${NC}"
    sleep 2
    exec ./scripts/data/all/v1/process/logs.sh
elif [[ "$user_choice" == "2" ]]; then
    echo -e "${YELLOW}Starting Data Processing (V2) in 2 seconds...${NC}"
    sleep 2
    exec ./scripts/data/all/v2/process/logs.sh
elif [[ "$user_choice" == "3" ]]; then
    echo -e "${YELLOW}Starting Data Processing (V3 - Server v6) in 2 seconds...${NC}"
    sleep 2
    
    # Display available folders and let user select
    echo ""
    echo "Select one of the available log folders in '00_DATA' directory:"
    folders=($(ls -d 00_DATA/*logs*/ 2>/dev/null))
    
    if [ ${#folders[@]} -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}No log folders found in '00_DATA'. Please ensure logs are available for processing.${NC}"
        sleep 3
        exec ./scripts/data/process/logs.sh
    fi
    
    for ((i=0; i<${#folders[@]}; i++)); do
        echo "$((i+1)). ${folders[i]#00_DATA/}"
    done
    
    echo ""
    read -p "Enter the number corresponding to the log folder you want to process: " folder_number
    
    # Validate user input
    if [[ ! $folder_number =~ ^[1-9][0-9]*$ || $folder_number -gt ${#folders[@]} ]]; then
        echo "Invalid input. Please enter a valid folder number. Exiting..."
        sleep 3
        exec ./scripts/data/process/logs.sh
    fi
    
    # Construct the full path to the selected folder
    selected_folder=${folders[$((folder_number-1))]#00_DATA/}
    
    # Run log-v6.py with the selected folder
    python3 ./scripts/data/process/processors/log-v6.py "$selected_folder"
    sleep 2
    exec ./scripts/data/main.sh
elif [[ "$user_choice" == "4" ]]; then
    echo -e "${YELLOW}Starting Data Processing (V4 - D-Hub) in 2 seconds...${NC}"
    sleep 2
    
    # Display available folders and let user select
    echo ""
    echo "Select one of the available log folders in '00_DATA' directory:"
    folders=($(ls -d 00_DATA/*logs*/ 2>/dev/null))
    
    if [ ${#folders[@]} -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}No log folders found in '00_DATA'. Please ensure logs are available for processing.${NC}"
        sleep 3
        exec ./scripts/data/process/logs.sh
    fi
    
    for ((i=0; i<${#folders[@]}; i++)); do
        echo "$((i+1)). ${folders[i]#00_DATA/}"
    done
    
    echo ""
    read -p "Enter the number corresponding to the log folder you want to process: " folder_number
    
    # Validate user input
    if [[ ! $folder_number =~ ^[1-9][0-9]*$ || $folder_number -gt ${#folders[@]} ]]; then
        echo "Invalid input. Please enter a valid folder number. Exiting..."
        sleep 3
        exec ./scripts/data/process/logs.sh
    fi
    
    # Construct the full path to the selected folder
    selected_folder=${folders[$((folder_number-1))]#00_DATA/}
    
    # Run dhub.py with the selected folder
    python3 ./scripts/data/process/processors/dhub.py "$selected_folder"
    sleep 2
    exec ./scripts/data/main.sh
else
    echo -e "${RED}Invalid choice. Please select 1, 2, 3, or 4.${NC}"
    echo -e "${YELLOW}Returning to the main menu...${NC}"
    sleep 2
    exec ./scripts/data/main.sh
fi
