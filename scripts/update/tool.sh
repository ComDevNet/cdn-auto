#!/bin/bash

# This script updates this tool while preserving local configurations.

# Save the current directory
current_directory=$(pwd)

# Move to the directory of the script
cd "$(dirname "$0")" || exit

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔄 Preparing to update...${NC}"
echo ""

# Only stash configuration files, not scripts
# This ensures script updates are preserved while configs are restored
echo "📦 Backing up your local configurations..."
git stash push -m "Local configuration backup before update" \
    config/ \
    .env \
    .env.local \
    > /dev/null 2>&1

# Fetch the latest changes from GitHub
echo "⬇️  Fetching latest changes from GitHub..."
git fetch origin > /dev/null 2>&1

# Reset to the latest remote version (gets all script updates)
echo "🔄 Applying updates..."
git reset --hard origin/$(git rev-parse --abbrev-ref HEAD) > /dev/null 2>&1

# Check if the update was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Script updated successfully.${NC}"
    echo ""
    
    # Restore ONLY configuration files
    echo "🔧 Restoring your configurations..."
    git stash pop > /dev/null 2>&1
    
    stash_result=$?
    if [ $stash_result -eq 0 ]; then
        echo -e "${GREEN}✅ Configurations restored.${NC}"
        echo ""
    elif [ $stash_result -eq 1 ]; then
        # Exit code 1 means no stash to pop (no configs were changed)
        echo -e "${GREEN}✅ No configuration changes to restore.${NC}"
        echo ""
    else
        echo -e "${YELLOW}⚠️  Could not automatically restore configurations.${NC}"
        echo -e "${YELLOW}You can manually restore them with: git stash pop${NC}"
        echo ""
    fi
else
    echo -e "${RED}❌ Failed to update the script. Please check for updates manually.${NC}"
    echo ""
    
    # Try to restore the stashed changes
    echo "Restoring stashed changes..."
    git stash pop > /dev/null 2>&1
    
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
sudo chmod +x scripts/data/all/v3/*.sh
sudo chmod +x scripts/data/all/v3/process/*.sh
sudo chmod +x scripts/data/all/v4/*.sh
sudo chmod +x scripts/data/all/v4/process/*.sh
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