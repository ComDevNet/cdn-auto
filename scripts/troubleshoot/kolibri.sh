#!/usr/bin/env bash

# Checks the status of kolibri and optionally restarts it.

echo "Checking the status of kolibri..."
kolibri status

# Prompt user about restart
read -r -p "Would you like to restart kolibri? [y/N]: " answer

case "$answer" in
  [Yy]* )
    echo "Restarting kolibri.service..."
    kolibri stop
    kolibri start
    echo "Restart complete. Checking status again..."
    kolibri status
    echo "Returning to troubleshoot menu..."
    sleep 3
    exec ./scripts/troubleshoot/main.sh
    ;;
  * )
    echo "Not restarting. Exiting."
    sleep 2
    exec ./scripts/troubleshoot/main.sh
    ;;
esac
