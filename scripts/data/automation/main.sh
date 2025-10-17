#!/bin/bash

# Clear the screen
clear
echo -e "\n\n"

# Function to safely pipe to lolcat if it exists, otherwise just cat
pipe_lolcat() {
  if command -v lolcat >/dev/null 2>&1; then
    lolcat
  else
    cat
  fi
}

# Display the name of the tool using figlet and lolcat
figlet -t -f 3d "AUTOMATION" | pipe_lolcat
echo ""

# Centered border with description
echo "=============================================================="
echo "  Install, Check Status, or Configure the Log Processor"
echo "=============================================================="
echo ""

# Color variables
RED='\033[0;31m'
NC='\033[0m' # No Color
DARK_GRAY='\033[1;30m'
GREEN='\033[0;32m'

# Display menu options with colors
echo -e "1. Install Automation   ${DARK_GRAY}-| Set up the systemd service and timer${NC}"
echo -e "2. Check Status         ${DARK_GRAY}-| Check the status of the automation service${NC}"
echo -e "3. Configure            ${DARK_GRAY}-| Configure automation parameters${NC}"
echo -e "${GREEN}4. Go Back              ${DARK_GRAY}-| Go back to the data menu${NC}"
echo -e "${RED}5. Exit                 ${DARK_GRAY}-| Exit the program${NC}"
echo ""

# Prompt the user for input
read -r -p "Choose an option (1-5): " choice

# Execute corresponding action based on user choice
case $choice in
    1)
        # Added sudo here to ensure the installer has root privileges
        sudo ./scripts/data/automation/install.sh
        # Pause to allow user to read the installer output before returning to menu
        read -r -p "Installation script finished. Press Enter to return to the menu..."
        exec ./scripts/data/automation/main.sh
        ;;
    2)
        ./scripts/data/automation/status.sh
        ;;
    3)
        # Added sudo to ensure the configure script has root privileges
        sudo ./scripts/data/automation/configure.sh
        # Pause to allow user to read the configure output before returning to menu
        read -r -p "Configuration script finished. Press Enter to return to the menu..."
        exec ./scripts/data/automation/main.sh
        ;;
    4)
        exec ./scripts/data/main.sh
        ;;
    5)
        ./exit.sh
        ;;
    *)
        echo -e "${RED}Invalid choice. Please choose a number between 1 and 5.${NC}"
        sleep 1.5
        exec ./scripts/data/automation/main.sh
        ;;
esac
