#!/bin/bash

clear
echo "=============================================================="
echo "  Select the log type you want to collect"
echo "=============================================================="
echo ""

# variables
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'

echo "1. v4 Logs (Apache)"
echo "2. v5 Logs (OC4D / Castle)"
echo "3. D-Hub Logs"
echo -e "${GREEN}4. Go Back${NC}"

echo ""
read -p "Choose an option (1-4): " choice

DEVICE_LOCATION="manual_collection"
TODAY_YMD=$(date '+%Y_%m_%d')
NEW_FOLDER="${DEVICE_LOCATION}_logs_${TODAY_YMD}"
COLLECT_DIR="00_DATA/$NEW_FOLDER"
mkdir -p "$COLLECT_DIR"

case $choice in
    1)
        LOG_DIR="/var/log/apache2"
        echo "Collecting v4 Apache logs from $LOG_DIR..."
        find "$LOG_DIR" -type f -name 'access.log*' -exec cp -v {} "$COLLECT_DIR"/ \;
        ;; 
    2)
        LOG_DIR="/var/log/oc4d"
        echo "Collecting v5 OC4D/Castle logs from $LOG_DIR..."
        find "$LOG_DIR" -type f \( -name 'oc4d-*.log' -o -name 'capecoastcastle-*.log' \) ! -name '*-exceptions-*' -exec cp -v {} "$COLLECT_DIR"/ \;
        ;;
    3)
        LOG_DIR="/var/log/dhub"
        echo "Collecting D-Hub logs from $LOG_DIR..."
        find "$LOG_DIR" -type f \( -name 'oc4d-*.log' ! -name 'oc4d-exceptions-*' \) -exec cp -v {} "$COLLECT_DIR"/ \;
        ;;
    4)
        exec ./scripts/data/main.sh
        ;;
    *)
        echo -e "${RED}Invalid choice.${NC}"
        sleep 1.5
        exec "$0"
        ;;
esac

echo -e "\n${GREEN}Log collection complete. Files are in: $COLLECT_DIR${NC}"
read -p "Press Enter to return to the menu..."
exec ./scripts/data/main.sh
