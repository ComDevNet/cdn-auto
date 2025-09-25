#!/bin/bash

# This script updates this tool.

# Save the current directory
current_directory=$(pwd)

# Move to the directory of the script
cd "$(dirname "$0")" || exit

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Pull the latest changes from GitHub
git reset --hard HEAD
git pull

# Check if the pull was successful
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}Script updated successfully.${NC}"
    echo ""
else
    echo -e "${RED}Failed to update the script. Please check for updates manually.${NC}"
    echo ""
    exit 1
fi

cd ../..

# Set execute permissions for all scripts in the current directory
sudo chmod +x *.sh
sudo chmod +x scripts/vpn/*.sh
sudo chmod +x scripts/update/*.sh
sudo chmod +x scripts/system/*.sh
sudo chmod +x scripts/system/networking/*.sh
sudo chmod +x scripts/data/*.sh
sudo chmod +x scripts/data/all/v1/*.sh
sudo chmod +x scripts/data/all/v1/process/*.sh
sudo chmod +x scripts/data/all/v2/*.sh
sudo chmod +x scripts/data/all/v2/process/*.sh
sudo chmod +x scripts/data/collection/*.sh
sudo chmod +x scripts/data/process/*.sh
sudo chmod +x scripts/data/upload/*.sh
sudo chmod +x scripts/troubleshoot/*.sh
sudo chmod +x scripts/data/automation/*.sh

# install python3 and pip3
pip3 install -r requirements.txt --break-system-packages
pip install -r requirements.txt --break-system-packages
pip3 install user-agents --break-system-packages
pip3 install tqdm --break-system-packages

# Return to the original directory
cd "$current_directory"

# Prompt the user to press Enter before returning to the main menu
echo ""
echo "Press Enter to return to the main menu..."
read -p ""

# Return to the main menu
exec ./scripts/update/main.sh