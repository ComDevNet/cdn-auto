#!/bin/bash

# --- Colors ---
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# This function checks if lolcat exists before trying to use it.
# If not, it falls back to a simple green color.
display_header() {
    HEADER="Install, Check Status, or Configure the Log Processor"
    if command -v lolcat &> /dev/null; then
        echo "========================================================" | lolcat
        echo "$HEADER" | lolcat
        echo "========================================================" | lolcat
    else
        # This is the fallback for when lolcat is not found
        echo -e "${GREEN}========================================================${NC}"
        echo -e "${GREEN}$HEADER${NC}"
        echo -e "${GREEN}========================================================${NC}"
    fi
}

# --- Main Menu ---
clear
display_header
echo ""
echo "1. Install Automation   | Set up the systemd service and timer"
echo "2. Check Status         | Check the status of the automation service"
echo "3. Configure            | Configure automation parameters"
echo -e "${YELLOW}4. Go Back              | Go back to the data menu${NC}"
echo -e "${RED}5. Exit                 | Exit the program${NC}"
echo ""
read -p "Choose an option (1-5): " choice

# Logic to handle user's choice
case "$choice" in
    1)
        sudo ./scripts/data/automation/install.sh
        ;;
    2)
        ./scripts/data/automation/status.sh
        ;;
    # Add cases for other options if they exist
    *)
        echo "Returning..."
        ;;
esac
