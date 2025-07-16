#!/bin/bash

# variables
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'

# Define the path to the hostapd configuration file
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"

# Function to check if wpa_passphrase is present in the configuration file
check_password_presence() {
    grep -E -q "^\s*wpa_passphrase=" "$HOSTAPD_CONF"
}

# Function to display the current password
show_current_password() {
    current_password=$(awk -F= '/^wpa_passphrase/ {print $2}' "$HOSTAPD_CONF" | tr -d '[:space:]')
    echo "Current WiFi Password: $current_password"
}

# Function to change the password
change_password() {
    show_current_password
    read -p "Enter the new WiFi password: " new_password
    sudo sed -i "s/^\(wpa_passphrase\s*=\s*\).*/\1$new_password/" "$HOSTAPD_CONF"
    echo -e "${GREEN}WiFi password changed.${NC}"
    echo "Restarting WiFi to apply changes..."
    sleep 2
    sudo systemctl restart hostapd
}

# Function to remove the password
remove_password() {
    sudo sed -i -e '/^wpa=/d; /^wpa_passphrase=/d; /^wpa_key_mgmt=/d; /^wpa_pairwise=/d; /^rsn_pairwise=/d; /^ieee80211n=/d; /^ht_capab=/d; /^country_code=/d' "$HOSTAPD_CONF"
    sudo sed -i "s/^wmm_enabled=.*/wmm_enabled=0/" "$HOSTAPD_CONF"
    echo -e "${GREEN}WiFi password removed.${NC}"
    echo "Restarting WiFi to apply changes..."
    sleep 2
    sudo systemctl restart hostapd
}

# Function to add password lines
add_password() {
    # Define the source file and the destination directory
    source_file="./files/hostapd_secure.conf"
    destination_dir="/etc/hostapd/"

    # Copy the source file to the destination directory and rename it
    sudo cp "$source_file" "$destination_dir"
    sudo mv "$destination_dir""hostapd_secure.conf" "$destination_dir""hostapd.conf"

    # Ask for the new WiFi password and SSID
    read -p "Enter the new WiFi password: " new_password
    read -p "Enter the new WiFi name: " new_ssid

    # Replace the placeholder password and SSID in the configuration with the new values
    sudo sed -i "s/^\(wpa_passphrase\s*=\s*\).*/\1$new_password/" "$destination_dir""hostapd.conf"
    sudo sed -i "s/^\(ssid\s*=\s*\).*/\1$new_ssid/" "$destination_dir""hostapd.conf"

    echo -e "${GREEN}WiFi password and Name added.${NC}"
    echo "Restarting WiFi to apply changes..."
    sleep 2

    # Restart the hostapd service
    sudo systemctl restart hostapd
}

echo " "
# Main menu
figlet -c -t -f 3d "WIFI PASSWORD MANAGER" | lolcat
echo " "

if check_password_presence; then
    # Prompt user for options
    echo "1. Change Password"
    echo "2. Remove Password"
    echo "3. Go Back"
    read -p "Enter the option number: " option

    case $option in
        1)
            change_password
            ;;
        2)
            remove_password
            ;;
        3)
            echo "Going back to the Main Menu..."
            sleep 1.5
            exec ./scripts/system/main.sh
            ;;
        *)
            echo -e "${RED}Invalid option. Going back to the main menu.${NC}"
            sleep 1.5
            exec ./scripts/system/wifi-password.sh
            ;;
    esac
else
    # If no password lines are present, ask if the user wants to add a password
    read -p "No WiFi password found. Do you want to add a password? (y/n): " add_password

    if [ "${add_password,}" == "y" ]; then
        add_password
    else
        echo "No password added. Going back to the main menu..."
        sleep 2
        exec ./scripts/system/main.sh
    fi
fi
