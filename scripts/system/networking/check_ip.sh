#!/bin/bash

echo ""
echo ""
# Telling the user command to exit and return to the main menu
echo "Press ctrl + C to exit and return to the main menu."

echo " "
echo " "

# Check the current IP addresses
tail -f -n 16 /var/log/networking/ip_changes.log

exec ./scripts/system/networking.sh
