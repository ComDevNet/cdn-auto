#!/bin/bash

# This script must be run with sudo to modify systemd files
if [ "$EUID" -ne 0 ]; then
  echo "❌ This script must be run with root privileges to modify the timer. Please use 'sudo'."
  exit 1
fi

# --- Configuration ---
SERVICE_NAME="v5-log-processor"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"
# This is a new config file where we'll store our settings
CONFIG_DIR="./config"
CONFIG_FILE="$CONFIG_DIR/automation.conf"

# --- Color Variables ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
CYAN='\033[0;36m'
BOLD=$(tput bold)
NORMAL=$(tput sgr0)

# --- Function to display current settings ---
show_current_config() {
    echo -e "--- ${CYAN}Current Configuration${NC} ---"
    
    # Load settings from config file if it exists
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    # Extract schedule from timer file
    CURRENT_SCHEDULE=$(grep -oP 'OnCalendar=\K.*' "$TIMER_FILE")

    echo -e "  ${BOLD}Server Version:${NORMAL}  ${YELLOW}${SERVER_VERSION:-Not Set}${NC}"
    echo -e "  ${BOLD}Device Location:${NORMAL} ${YELLOW}${DEVICE_LOCATION:-Not Set}${NC}"
    echo -e "  ${BOLD}Python Script:${NORMAL}   ${YELLOW}${PYTHON_SCRIPT:-Not Set}${NC}"
    echo -e "  ${BOLD}S3 Bucket:${NORMAL}       ${YELLOW}${S3_BUCKET:-Not Set}${NC}"
    echo -e "  ${BOLD}Run Schedule:${NORMAL}    ${YELLOW}${CURRENT_SCHEDULE:-Not Set}${NC}"
    echo ""
}

# --- Script Start ---
clear
echo ""
figlet -t -f 3d "CONFIGURE" | lolcat
echo ""
echo "=============================================================="
echo "      Customize the V5 Log Processor Automation"
echo "=============================================================="
echo ""

# First, check if the timer file exists.
if [ ! -f "$TIMER_FILE" ]; then
  echo -e "${RED}❌ Automation service not found!${NC}"
  echo "   Cannot configure something that has not been installed."
  echo "   Please run the 'Install Automation' option first."
  echo ""
  read -p "Press Enter to return to the menu..."
  exit 0
fi

# Display current settings before asking for new ones
show_current_config

# --- Prompt for New Settings ---
echo -e "--- ${CYAN}Enter New Settings${NC} ---"
echo "Press Enter to keep the current value."
echo ""

# Load current values to use as defaults in prompts
source "$CONFIG_FILE" 2>/dev/null

read -p "  Enter server version [${YELLOW}${SERVER_VERSION:-None}${NC}]: " NEW_SERVER_VERSION
SERVER_VERSION=${NEW_SERVER_VERSION:-$SERVER_VERSION}

read -p "  Enter device location [${YELLOW}${DEVICE_LOCATION:-None}${NC}]: " NEW_DEVICE_LOCATION
DEVICE_LOCATION=${NEW_DEVICE_LOCATION:-$DEVICE_LOCATION}

read -p "  Enter S3 Bucket name [${YELLOW}${S3_BUCKET:-None}${NC}]: " NEW_S3_BUCKET
S3_BUCKET=${NEW_S3_BUCKET:-$S3_BUCKET}

echo ""
echo "  Select the Python processing script:"
PS3="  Your choice: "
select script_choice in "oc4d_processor.py" "cape_coast_d_processor.py" "Skip"; do
    case $script_choice in
        "oc4d_processor.py")
            PYTHON_SCRIPT="oc4d_processor.py"
            break
            ;;
        "cape_coast_d_processor.py")
            PYTHON_SCRIPT="cape_coast_d_processor.py"
            break
            ;;
        "Skip")
            echo "  Skipping Python script selection."
            break
            ;;
        *) 
            echo "Invalid option. Please choose 1, 2, or 3."
            ;;
    esac
done
echo ""

echo "  Select the automation run schedule:"
PS3="  Your choice: "
select schedule_choice in "Hourly" "Daily" "Monthly" "Custom"; do
    case $schedule_choice in
        "Hourly")
            NEW_SCHEDULE="hourly"
            break
            ;;
        "Daily")
            NEW_SCHEDULE="daily"
            break
            ;;
        "Monthly")
            NEW_SCHEDULE="monthly"
            break
            ;;
        "Custom")
            echo "  Enter a custom systemd calendar expression."
            echo "  (e.g., '*-*-* 0/2:00:00' for every 2 hours, 'weekly' for once a week)"
            read -p "  Custom schedule: " CUSTOM_SCHEDULE
            NEW_SCHEDULE=$CUSTOM_SCHEDULE
            break
            ;;
        *) 
            echo "Invalid option. Please choose 1, 2, 3, or 4."
            ;;
    esac
done

# --- Save and Apply Changes ---
echo ""
echo -e "--- ${CYAN}Applying New Configuration...${NC} ---"

# 1. Save data settings to the config file
echo "  Saving settings to $CONFIG_FILE..."
mkdir -p "$CONFIG_DIR"
# Sanitize variables to ensure they are quoted correctly for the file
{
    echo "SERVER_VERSION=\"$SERVER_VERSION\""
    echo "DEVICE_LOCATION=\"$DEVICE_LOCATION\""
    echo "PYTHON_SCRIPT=\"$PYTHON_SCRIPT\""
    echo "S3_BUCKET=\"$S3_BUCKET\""
} > "$CONFIG_FILE"
echo -e "  ${GREEN}✅ Settings saved.${NC}"

# 2. Update the systemd timer file with the new schedule
echo "  Updating systemd timer schedule to '$NEW_SCHEDULE'..."
# Use sed to replace the OnCalendar line. The weird separator `|` is to avoid issues if the custom schedule contains `/`
sed -i "s|^OnCalendar=.*|OnCalendar=$NEW_SCHEDULE|" "$TIMER_FILE"
echo -e "  ${GREEN}✅ Timer file updated.${NC}"

# 3. Reload systemd and restart the timer to apply the new schedule
echo "  Reloading systemd daemon and restarting timer..."
systemctl daemon-reload
systemctl restart "$SERVICE_NAME.timer"
echo -e "  ${GREEN}✅ Systemd reloaded and timer restarted.${NC}"

echo ""
echo "=============================================================="
echo -e "🎉 ${GREEN}Configuration updated successfully!${NC}"
echo "=============================================================="
echo ""
show_current_config

read -p "Press Enter to return to the menu..."