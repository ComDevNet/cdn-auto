#!/usr/bin/env bash

# An interactive script to enable and connect a USB modem to the internet using mmcli.

########################
# Helper Functions
########################

pause_for_confirmation() {
  local prompt_msg="$1"
  while true; do
    read -r -p "$prompt_msg [y/N]: " answer
    case "$answer" in
      [Yy]* ) 
        break  # user confirmed, break out of the loop and continue the script
        ;;
      [Nn]* | "" )
        echo ""
        echo "Please do any required steps or checks manually, then press 'y' to continue."
        echo "Waiting..."
        # We simply loop here until the user presses 'y'
        ;;
      * )
        echo "Please answer 'y' or 'n'."
        ;;
    esac
  done
}


########################
# 1) Check for mmcli
########################
if ! command -v mmcli &> /dev/null; then
  echo ""
  echo "Error: 'mmcli' command not found. Please install ModemManager."
  sleep 2
  exec ./scripts/system/main.sh 
fi

echo ""
echo "mmcli is installed: $(mmcli -V)"
pause_for_confirmation "Do you want to continue?"

########################
# 2) Scan for modems
########################
echo ""
echo "Scanning for modems..."
echo ""
sudo mmcli --scan-modems
pause_for_confirmation "Continue?"

########################
# 3) List available modems
########################
modem_list=$(sudo mmcli --list-modems 2>&1)
echo ""
echo "List of modems:"
echo ""
echo "$modem_list"

# If no modems found, exit (fatal)
if echo "$modem_list" | grep -q "No modems were found"; then
  echo ""
  echo "No modems found. Please ensure your USB modem is plugged in."
  sleep 2
  exec ./scripts/system/main.sh
fi

pause_for_confirmation "Continue?"

########################
# 4) Ask user which modem to manage
########################
echo ""
echo "Which modem index do you want to manage?"
# Typically, mmcli --list-modems shows something like: /org/freedesktop/ModemManager1/Modem/0 
# We can parse out the last digit as the modem index. Or ask the user to specify.
read -r -p "Enter modem index (e.g. 0): " MODEM_INDEX
if [ -z "$MODEM_INDEX" ]; then
  echo ""
  echo "No modem index provided. Nothing to manage at the moment."
  # Instead of exiting, we just loop forever until user provides it
  while [ -z "$MODEM_INDEX" ]; do
    echo ""
    echo "Please enter a valid modem index to continue."
    read -r -p "Modem index: " MODEM_INDEX
  done
fi

pause_for_confirmation "Use modem index $MODEM_INDEX and continue?"

########################
# 5) Check modem info & status
########################
echo ""
echo "Fetching modem info..."
modem_info=$(sudo mmcli --modem="$MODEM_INDEX" 2>&1)
if echo "$modem_info" | grep -iq "error"; then
  echo ""
  echo "Error fetching modem info. Please check the index or connections."
  # We won't exit. We'll loop until the user fixes it or chooses to skip
  while echo "$modem_info" | grep -iq "error"; do
    echo ""
    echo "Please fix any issues (check USB cable, etc.) or pick another modem index."
    pause_for_confirmation "When ready, press 'y' to try again."

    # let them re-enter the modem index if they want to
    read -r -p "Enter a new modem index or press Enter to reuse $MODEM_INDEX: " NEW_INDEX
    [ -n "$NEW_INDEX" ] && MODEM_INDEX="$NEW_INDEX"
    echo ""
    echo "Trying again with modem index $MODEM_INDEX..."
    modem_info=$(sudo mmcli --modem="$MODEM_INDEX" 2>&1)
  done
fi

echo ""
echo "$modem_info"
pause_for_confirmation "Continue?"

# A quick way to see if modem is connected:
echo ""
echo "Checking modem state..."
modem_state=$(echo "$modem_info" | grep -i "state" | grep -oE "connected|connecting|registered|disabled|enabling|enabled|failed|unknown")
if [ -z "$modem_state" ]; then
  modem_state="unknown"
fi
echo ""
echo "Modem state appears to be: $modem_state"

# Check if connected
if [ "$modem_state" = "connected" ]; then
  echo ""
  echo "It appears your modem is already connected."
  pause_for_confirmation "Do you want to continue (e.g., check IP type)?"
else
  echo ""
  echo "Modem is not fully connected."
  pause_for_confirmation "Would you like to attempt to connect now?"
  
  # 5a) Enable the modem if not enabled
  echo ""
  echo "Enabling modem..."
  sudo mmcli --modem="$MODEM_INDEX" --enable
  pause_for_confirmation "Modem enabled (if it wasn't already). Continue to connect?"
  
  # 5b) Connect (APN & IP type can be adjusted as needed)
  # Prompt user for APN if you like:
  echo ""
  read -r -p "Enter APN (default: data.tre.se): " USER_APN
  APN=${USER_APN:-data.tre.se}
  
  # Prompt user for IP type (ipv4, ipv6, ipv4v6)
  echo ""
  read -r -p "Enter IP type (ipv4, ipv6, or ipv4v6) [default: ipv4v6]: " USER_IPTYPE
  IPTYPE=${USER_IPTYPE:-ipv4v6}
  
  echo ""
  echo "Attempting to activate data connection with APN=$APN, IP_TYPE=$IPTYPE..."
  sudo mmcli -m "$MODEM_INDEX" --simple-connect="apn=$APN,ip-type=$IPTYPE"
  
  # Re-check status
  echo ""
  echo "Re-checking modem status..."
  modem_info=$(sudo mmcli --modem="$MODEM_INDEX")
  echo "$modem_info"
fi

pause_for_confirmation "Continue to check final connection details?"

########################
# 6) Check current bearer (IP type)
########################
bearer_line=$(echo "$modem_info" | grep -iE 'Bearer.*\/Modem')
if [ -n "$bearer_line" ]; then
  bearer_id=$(echo "$bearer_line" | awk -F'/' '{print $NF}')
  echo ""
  echo "Detected bearer ID: $bearer_id"
  
  echo ""
  echo "Fetching bearer info..."
  bearer_info=$(sudo mmcli --bearer="$bearer_id" 2>&1)
  echo "$bearer_info"
  
  # parse out IP type or addresses
  ip_family=$(echo "$bearer_info" | grep -oE "ipv[46]{1,2}")
  [ -z "$ip_family" ] && ip_family="unknown"
  
  echo ""
  echo "Your current IP family/type appears to be: $ip_family"
else
echo ""
  echo "No bearer found. The modem might not be fully connected."
fi

pause_for_confirmation "Done checking details. Return to main menu?"

echo ""
echo "Returning to main menu..."
sleep 2
exec ./scripts/system/main.sh
