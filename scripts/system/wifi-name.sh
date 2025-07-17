#!/bin/bash

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Define the path to the hostapd configuration file
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"

# Function to display current wifi name
show_current_wifi_name() {
    current_wifi_name=$(awk -F= '/^ssid/ {print $2}' "$HOSTAPD_CONF" | tr -d '[:space:]')
    echo "Current WiFi Name: $current_wifi_name"
}

# Function to change wifi name
change_wifi_name() {
    read -p "Enter the new WiFi name: " new_wifi_name
    sudo sed -i "s/^ssid=.*/ssid=$new_wifi_name/" "$HOSTAPD_CONF"
    echo "WiFi name changed to: $new_wifi_name"

    read -p "Needs to restart wifi to apply changes. Do you want to continue? (y/n): " choice
    if [ "${choice,}" == "y" ]; then
        echo "WIFI restarting...."
        sleep 1.5
        sudo systemctl restart hostapd
    else
        echo "Wifi name changes will be applied after device has been rebooted. Returning to main menu...."
        sleep 2
        exec ./scripts/system/main.sh
    fi
}

# Display current wifi name
show_current_wifi_name

# Ask user if they want to change the wifi name
read -p "Do you want to change the WiFi name? (y/n): " choice

if [ "${choice,}" == "y" ]; then
    # Call function to change wifi name
    change_wifi_name
elif [ "${choice,}" == "n" ]; then
    echo "Returning to Main Menu....."
    sleep 2
    exec ./scripts/system/main.sh
else
    echo -e "${RED}Invalid choice. Please enter 'y' or 'n'.${NC}"
fi
