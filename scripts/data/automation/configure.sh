#!/bin/bash

# This script must be run with sudo to modify systemd files
if [ "$EUID" -ne 0 ]; then
  echo "❌ This script must be run with root privileges to modify the timer."
  echo "   Please run it from the automation menu."
  exit 1
fi

# --- Configuration ---
SERVICE_NAME="v5-log-processor"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"
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
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    CURRENT_SCHEDULE=$(grep -oP 'OnCalendar=\K.*' "$TIMER_FILE")

    echo -e "  ${BOLD}Server Version:${NORMAL}  ${YELLOW}${SERVER_VERSION:-Not Set}${NC}"
    echo -e "  ${BOLD}Device Location:${NORMAL} ${YELLOW}${DEVICE_LOCATION:-Not Set}${NC}"
    echo -e "  ${BOLD}Python Script:${NORMAL}   ${YELLOW}${PYTHON_SCRIPT:-Not Set}${NC}"
    echo -e "  ${BOLD}S3 Bucket:${NORMAL}       ${YELLOW}${S3_BUCKET:-Not Set}${NC}"
    echo -e "  ${BOLD}S3 Subfolder:${NORMAL}    ${YELLOW}${S3_SUBFOLDER:-Not Set}${NC}"
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

if [ ! -f "$TIMER_FILE" ]; then
  echo -e "${RED}❌ Automation service not found!${NC}"
  echo "   Please run the 'Install Automation' option first."
  echo ""
  read -p "Press Enter to return to menu..."
  exec ./scripts/data/automation/main.sh
fi

show_current_config

# --- Prompt for New Settings ---
echo -e "--- ${CYAN}Enter New Settings${NC} ---"

source "$CONFIG_FILE" 2>/dev/null

# --- Server Version Selection ---
echo "  Select the server version:"
PS3="  Your choice: "
select version_choice in "v4" "v5" "Skip Selection"; do
    case $version_choice in
        "v4"|"v5") SERVER_VERSION=$version_choice; break ;;
        "Skip Selection") echo "  Skipping server version, keeping current."; break ;;
        *) echo "Invalid option. Please choose 1, 2, or 3." ;;
    esac
done
echo ""

# --- Device Location (Manual Input) ---
echo "  Enter the device location (e.g., 'Accra-Main-Office'):"
read -p "  [${YELLOW}${DEVICE_LOCATION:-None}${NC}]: " NEW_DEVICE_LOCATION
DEVICE_LOCATION=${NEW_DEVICE_LOCATION:-$DEVICE_LOCATION}
echo ""

# --- Python Script Selection ---
echo "  Select the Python processing script:"
PS3="  Your choice: "
select script_choice in "oc4d" "cape_coast_d" "Skip Selection"; do
    case $script_choice in
        "oc4d"|"cape_coast_d") PYTHON_SCRIPT=$script_choice; break ;;
        "Skip Selection") echo "  Skipping Python script selection, keeping current."; break ;;
        *) echo "Invalid option. Please choose 1, 2, or 3." ;;
    esac
done
echo ""

# --- Get S3 Bucket from upload.sh (like your existing system) ---
echo "  Getting S3 bucket configuration from upload.sh..."
S3_BUCKET=$(grep -oP '(?<=s3_bucket=).+' scripts/data/upload/upload.sh 2>/dev/null | tr -d '"')

if [ -z "$S3_BUCKET" ]; then
    echo -e "${YELLOW}⚠️ No S3 bucket found in upload.sh${NC}"
    read -p "  Enter the S3 bucket URL (e.g., s3://my-bucket): " MANUAL_BUCKET
    S3_BUCKET=${MANUAL_BUCKET:-$S3_BUCKET}
else
    echo -e "  ${GREEN}Found S3 bucket: ${YELLOW}$S3_BUCKET${NC}"
    read -p "  Keep this bucket? (y/n): " keep_bucket
    if [[ $keep_bucket != "y" && $keep_bucket != "Y" ]]; then
        read -p "  Enter new S3 bucket URL: " NEW_BUCKET
        S3_BUCKET=${NEW_BUCKET:-$S3_BUCKET}
    fi
fi
echo ""

# --- S3 SUBFOLDER SELECTION (Like your upload system) ---
echo "  Select S3 subfolder where logs will be uploaded:"

# Check if AWS CLI is installed and S3 bucket is accessible
if ! command -v aws &> /dev/null; then
    echo -e "${YELLOW}⚠️ AWS CLI not found. Please enter subfolder name manually.${NC}"
    read -p "  Enter subfolder name: " MANUAL_SUBFOLDER
    S3_SUBFOLDER=${MANUAL_SUBFOLDER:-$S3_SUBFOLDER}
else
    if [ -n "$S3_BUCKET" ]; then
        echo "  Fetching available subfolders from $S3_BUCKET..."
        
        # Get subfolders from S3 bucket (similar to your upload script)
        mapfile -t subfolders < <(aws s3 ls "$S3_BUCKET/" | grep "PRE" | awk '{print $2}' | sed 's|/||' | sort)
        
        if [ ${#subfolders[@]} -eq 0 ]; then
            echo -e "${YELLOW}  No subfolders found in bucket.${NC}"
            read -p "  Enter subfolder name manually: " MANUAL_SUBFOLDER
            S3_SUBFOLDER=${MANUAL_SUBFOLDER:-$S3_SUBFOLDER}
        else
            echo "  Available subfolders:"
            # Add manual entry options to the list
            options=("${subfolders[@]}" "Other (Enter Manually)" "Skip Selection")

            PS3="  Your choice: "
            select subfolder_choice in "${options[@]}"; do
                if [[ " ${subfolders[*]} " =~ " ${subfolder_choice} " ]]; then
                    # If the choice is one of the fetched subfolders
                    S3_SUBFOLDER="$subfolder_choice"
                    echo "  You selected: $S3_SUBFOLDER"
                    break
                elif [[ "$subfolder_choice" == "Other (Enter Manually)" ]]; then
                    read -p "  Enter custom subfolder name: " CUSTOM_SUBFOLDER
                    S3_SUBFOLDER=${CUSTOM_SUBFOLDER:-$S3_SUBFOLDER}
                    break
                elif [[ "$subfolder_choice" == "Skip Selection" ]]; then
                    echo "  Skipping subfolder selection, keeping current."
                    break
                else
                    echo "Invalid selection. Please try again."
                fi
            done
        fi
    else
        echo -e "${RED}  No S3 bucket configured. Skipping subfolder selection.${NC}"
    fi
fi
echo ""

# --- Schedule Selection ---
echo "  Select the automation run schedule:"
PS3="  Your choice: "
select schedule_choice in "1 Hour" "Daily" "Monthly" "Custom (seconds)"; do
    case $schedule_choice in
        "1 Hour") NEW_SCHEDULE="hourly"; RUN_INTERVAL="3600"; break ;;
        "Daily") NEW_SCHEDULE="daily"; RUN_INTERVAL="86400"; break ;;
        "Monthly") NEW_SCHEDULE="monthly"; RUN_INTERVAL="2629746"; break ;;
        "Custom (seconds)")
            echo "  Enter interval in seconds:"
            echo "    - 1 hour = 3600 seconds"
            echo "    - 1 day = 86400 seconds"
            echo "    - 1 week = 604800 seconds"
            read -p "  Interval in seconds: " CUSTOM_SECONDS
            
            if [[ "$CUSTOM_SECONDS" =~ ^[0-9]+$ ]] && [ "$CUSTOM_SECONDS" -gt 0 ]; then
                RUN_INTERVAL="$CUSTOM_SECONDS"
                # Convert to systemd timer format
                if [ "$CUSTOM_SECONDS" -eq 3600 ]; then
                    NEW_SCHEDULE="hourly"
                elif [ "$CUSTOM_SECONDS" -eq 86400 ]; then
                    NEW_SCHEDULE="daily"
                elif [ "$CUSTOM_SECONDS" -eq 604800 ]; then
                    NEW_SCHEDULE="weekly"
                elif [ "$CUSTOM_SECONDS" -eq 2629746 ]; then
                    NEW_SCHEDULE="monthly"
                else
                    # For custom intervals, use OnUnitActiveSec
                    NEW_SCHEDULE="custom"
                fi
                break
            else
                echo "  Invalid input. Please enter a positive number."
            fi
            ;;
        *) echo "Invalid option. Try again." ;;
    esac
done

# --- Save and Apply Changes ---
echo ""
echo -e "--- ${CYAN}Applying New Configuration...${NC} ---"

mkdir -p "$CONFIG_DIR"
{
    echo "# V5 Log Processor Automation Configuration"
    echo "# Generated on $(date)"
    echo ""
    echo "SERVER_VERSION=\"$SERVER_VERSION\""
    echo "DEVICE_LOCATION=\"$DEVICE_LOCATION\""
    echo "PYTHON_SCRIPT=\"$PYTHON_SCRIPT\""
    echo "S3_BUCKET=\"$S3_BUCKET\""
    echo "S3_SUBFOLDER=\"$S3_SUBFOLDER\""
    echo "RUN_INTERVAL=\"$RUN_INTERVAL\""
    echo "SCHEDULE_TYPE=\"$NEW_SCHEDULE\""
    echo ""
    echo "# Derived settings"
    echo "CONFIG_UPDATED=\"$(date '+%Y-%m-%d %H:%M:%S')\""
} > "$CONFIG_FILE"
echo -e "  ${GREEN}✅ Settings saved to $CONFIG_FILE.${NC}"

# Update timer file based on schedule type
if [ "$NEW_SCHEDULE" == "custom" ]; then
    # Use OnUnitActiveSec for custom intervals
    sed -i "s|^OnCalendar=.*|OnUnitActiveSec=${RUN_INTERVAL}sec|" "$TIMER_FILE"
    # Remove OnCalendar if it exists when using custom interval
    sed -i "/^OnCalendar=/d" "$TIMER_FILE"
    # Add OnUnitActiveSec after OnBootSec if not already there
    if ! grep -q "OnUnitActiveSec" "$TIMER_FILE"; then
        sed -i "/OnBootSec=/a OnUnitActiveSec=${RUN_INTERVAL}sec" "$TIMER_FILE"
    fi
else
    # Use OnCalendar for standard schedules
    sed -i "s|^OnCalendar=.*|OnCalendar=$NEW_SCHEDULE|" "$TIMER_FILE"
    sed -i "s|^OnUnitActiveSec=.*|OnUnitActiveSec=$NEW_SCHEDULE|" "$TIMER_FILE"
fi
echo -e "  ${GREEN}✅ Timer file updated.${NC}"

systemctl daemon-reload
systemctl restart "$SERVICE_NAME.timer"
echo -e "  ${GREEN}✅ Systemd reloaded and timer restarted.${NC}"

echo ""
echo "=============================================================="
echo -e "🎉 ${GREEN}Configuration updated successfully!${NC}"
echo "=============================================================="
echo ""
show_current_config

echo -e "--- ${CYAN}Configuration Summary${NC} ---"
echo -e "  The automation will now:"
echo -e "  📁 Process logs for: ${YELLOW}$DEVICE_LOCATION${NC}"
echo -e "  🐍 Using Python script: ${YELLOW}${PYTHON_SCRIPT}${NC}"
echo -e "  ☁️  Upload to: ${YELLOW}${S3_BUCKET}/${S3_SUBFOLDER}/RACHEL/${NC}"
echo -e "  ⏰ Run every: ${YELLOW}${RUN_INTERVAL} seconds (${NEW_SCHEDULE})${NC}"
echo -e "  🖥️  Server version: ${YELLOW}${SERVER_VERSION}${NC}"
echo ""

# Enable the timer if not already enabled
if ! systemctl is-enabled --quiet "$SERVICE_NAME.timer"; then
    systemctl enable "$SERVICE_NAME.timer"
    echo -e "  ${GREEN}✅ Automation enabled (will start on boot).${NC}"
fi

echo ""
read -p "Press Enter to return to automation menu..."
exec ./scripts/data/automation/main.sh