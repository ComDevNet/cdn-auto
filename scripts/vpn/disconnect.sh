#!/bin/bash

# Define color variables for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo ""
# Check if zerotier-cli is installed
if ! command -v zerotier-cli &> /dev/null; then
    echo -e "${RED}Error:${NC} zerotier-cli is not installed. Please install it before running this script."
    echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
    read -p ""
    exec ./scripts/vpn/main.sh
fi

# Disconnect from all ZeroTier networks
echo -e "${YELLOW}Disconnecting from all ZeroTier networks...${NC}"

# Get the list of active network IDs
network_ids=$(sudo zerotier-cli listnetworks | awk '/OK/ {print $3}')

if [[ -z "$network_ids" ]]; then
    echo -e "${RED}No active networks to disconnect from.${NC}"
else
    # Loop through each network ID and leave the network
    for network_id in $network_ids; do
        sudo zerotier-cli leave "$network_id"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Successfully disconnected from network ID: $network_id${NC}"
        else
            echo -e "${RED}Failed to disconnect from network ID: $network_id${NC}"
        fi
    done
fi

# Wait for the user to press Enter before returning to the main menu
echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
read -p ""
exec ./scripts/vpn/main.sh
