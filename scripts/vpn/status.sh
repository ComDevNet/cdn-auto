#!/bin/bash

# Define color variables
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo ""

# Check if zerotier-cli is installed
if ! command -v zerotier-cli &> /dev/null; then
    echo -e "${RED}Error:${NC} zerotier-cli is not installed."
    echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
    read -p ""
    exec ./scripts/vpn/main.sh
fi

echo -e "${YELLOW}Checking current ZeroTier networks...${NC}"
echo ""

# Capture listnetworks once; status must never join or regenerate identity
networks_output=$(sudo zerotier-cli listnetworks 2>&1)
active_networks=$(echo "$networks_output" | grep "OK" || true)

if [[ -n "$active_networks" ]]; then
    echo -e "${GREEN}Active Connection:${NC}"
    echo "$active_networks"
else
    echo -e "${RED}No authorized networks found.${NC}"
    # Show any pending/non-OK networks so the user can see join state without reconnecting
    pending_networks=$(echo "$networks_output" | awk 'NR>1 && $0 !~ /OK/ {print}' || true)
    if [[ -n "$pending_networks" ]]; then
        echo ""
        echo -e "${YELLOW}Pending / other networks:${NC}"
        echo "$pending_networks"
    fi
fi

echo ""
echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
read -p ""
exec ./scripts/vpn/main.sh
