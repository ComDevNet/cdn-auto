#!/bin/bash

echo ""
echo ""
# Telling the user command to exit and return to the main menu
echo "Press ctrl + C to exit and return to the main menu."

echo " "
echo " "

# Check the current IP addresses
tail -n 16 /var/log/networking/ip_changes.log


# Prompt the user to press Enter before returning to the main menu
echo ""
echo "Press Enter to return to the main menu..."
read -p ""

exec ./scripts/system/networking.sh
