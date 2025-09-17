#!/bin/bash

# --- Configuration ---
# These variables must match the ones in the install.sh script
SERVICE_NAME="v5-log-processor"
LOG_FILE="/var/log/v5_log_processor/automation.log"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"

# --- Color Variables ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
CYAN='\033[0;36m'

# --- Script Start ---
clear

echo ""
echo ""

# Display the title
figlet -t -f 3d "STATUS" | lolcat

echo ""
echo "=============================================================="
echo "   Checking the status of the V5 Log Processor Automation"
echo "=============================================================="

echo ""

# First, check if the timer file exists at all.
if [ ! -f "$TIMER_FILE" ]; then
  echo -e "${RED}❌ Automation service not found!${NC}"
  echo "   It looks like the automation has not been installed yet."
  echo "   Please run the 'Install Automation' option from the menu first."
  echo ""
  read -p "Press Enter to return to the menu..."
  exec ./scripts/data/automation/main.sh
fi

# --- Systemd Timer Status ---
echo -e "--- ${CYAN}Systemd Timer Status ($SERVICE_NAME.timer)${NC} ---"
# Use --no-pager to print the full status and exit immediately
systemctl status "$SERVICE_NAME.timer" --no-pager

echo ""
echo ""

# --- Service Status ---
echo -e "--- ${CYAN}Systemd Service Status ($SERVICE_NAME.service)${NC} ---"
systemctl status "$SERVICE_NAME.service" --no-pager

echo ""
echo ""

# --- Timer Schedule Information ---
echo -e "--- ${CYAN}Timer Schedule Information${NC} ---"
echo -e "Next scheduled run:"
systemctl list-timers "$SERVICE_NAME.timer" --no-pager | grep -A 1 "NEXT"

echo ""
echo ""

# --- Recent Activity Log ---
echo -e "--- ${CYAN}Recent Activity Log (Last 20 lines of $LOG_FILE)${NC} ---"
if [ -f "$LOG_FILE" ]; then
  # Check if log file has content before trying to display it
  if [ -s "$LOG_FILE" ]; then
    tail -n 20 "$LOG_FILE"
  else
    echo -e "${YELLOW}Log file is currently empty.${NC}"
    echo "The automation might not have run yet."
    echo "The first run is scheduled for 5 minutes after boot, and daily thereafter."
  fi
else
  echo -e "${YELLOW}Log file not found.${NC}"
  echo "The automation has likely not run for the first time."
fi

echo ""
echo ""

# --- Additional Status Information ---
echo -e "--- ${CYAN}Additional Status Information${NC} ---"

# Check if timer is enabled
if systemctl is-enabled --quiet "$SERVICE_NAME.timer"; then
    echo -e "${GREEN}✅ Timer is enabled (will start on boot)${NC}"
else
    echo -e "${RED}❌ Timer is disabled (will not start on boot)${NC}"
fi

# Check if timer is active
if systemctl is-active --quiet "$SERVICE_NAME.timer"; then
    echo -e "${GREEN}✅ Timer is currently active and running${NC}"
else
    echo -e "${RED}❌ Timer is currently inactive${NC}"
fi

# Check wrapper script
WRAPPER_SCRIPT="/usr/local/bin/run_v5_log_processor.sh"
if [ -x "$WRAPPER_SCRIPT" ]; then
    echo -e "${GREEN}✅ Wrapper script exists and is executable${NC}"
else
    echo -e "${RED}❌ Wrapper script missing or not executable${NC}"
fi

# Check log directory permissions
LOG_DIR="/var/log/v5_log_processor"
if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    echo -e "${GREEN}✅ Log directory exists and is writable${NC}"
else
    echo -e "${RED}❌ Log directory missing or not writable${NC}"
fi

echo ""
echo "=============================================================="
echo -e "💡 ${CYAN}Useful Commands:${NC}"
echo ""
echo -e "   📋 View live log in real-time:"
echo -e "      ${GREEN}tail -f $LOG_FILE${NC}"
echo ""
echo -e "   🚀 Manually trigger a run:"
echo -e "      ${GREEN}sudo systemctl start $SERVICE_NAME.service${NC}"
echo ""
echo -e "   ⏹️  Stop the automation:"
echo -e "      ${GREEN}sudo systemctl stop $SERVICE_NAME.timer${NC}"
echo ""
echo -e "   ▶️  Start the automation:"
echo -e "      ${GREEN}sudo systemctl start $SERVICE_NAME.timer${NC}"
echo ""
echo -e "   🔄 Restart the automation:"
echo -e "      ${GREEN}sudo systemctl restart $SERVICE_NAME.timer${NC}"
echo ""
echo -e "   📊 View systemd journal for this service:"
echo -e "      ${GREEN}journalctl -u $SERVICE_NAME.service -f${NC}"
echo ""

read -p "Press Enter to return to the menu..."
exec ./scripts/data/automation/main.sh