#!/usr/bin/env bash

# Checks the status of hostapd.service and optionally restarts it.

# 1) Check the status of hostapd.service
echo "Checking the status of hostapd.service..."
sudo systemctl status hostapd.service

# 2) Prompt the user
read -r -p "Would you like to restart hostapd.service? [y/N]: " answer

# 3) If yes, restart; otherwise, do nothing
case "$answer" in
  [Yy]* )
    echo "Restarting hostapd.service..."
    sudo systemctl restart hostapd.service
    echo "Restart complete. Checking status again..."
    sudo systemctl status hostapd.service
    exec ./scripts/troubleshoot/main.sh
    ;;
  * )
    echo "Not restarting. Returning to main menu..."
    sleep 2
    exec ./scripts/troubleshoot/main.sh
    ;;
esac
