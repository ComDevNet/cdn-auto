#!/usr/bin/env bash

# Checks the status of oc4d.service and optionally restarts it.

# 1) Check the status of oc4d.service
echo "Checking the status of oc4d.service..."
sudo systemctl status oc4d.service

# 2) Prompt the user
read -r -p "Would you like to restart oc4d.service? [y/N]: " answer

# 3) If yes, restart; otherwise, do nothing
case "$answer" in
  [Yy]* )
    echo "Restarting oc4d.service..."
    sudo systemctl restart oc4d.service
    echo "Restart complete. Checking status again..."
    sudo systemctl status oc4d.service
    exec ./scripts/troubleshoot/main.sh
    ;;
  * )
    echo "Not restarting. Returning to main menu..."
    sleep 2
    exec ./scripts/troubleshoot/main.sh
    ;;
esac
