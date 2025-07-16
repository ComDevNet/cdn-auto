#!/bin/bash

echo ""
echo "Server Types:"
echo "1. V4 Logs (Located at /var/log/apache2)"
echo "2. V5 Logs (Located at /var/log/oc4d)"
echo ""

# Prompt the user to select the log type
read -p "Please select the type of logs to collect (1 for V4, 2 for V5): " log_choice

# Set the log directory and collection logic based on the user's selection
case $log_choice in
    1)
        log_directory="/var/log/apache2"
        log_type="V4 Logs"
        ;;
    2)
        log_directory="/var/log/oc4d"
        log_type="V5 Logs"
        ;;
    *)
        echo "Invalid choice. Please run the script again and choose either 1 or 2."
        exit 1
        ;;
esac

echo ""
echo "You have selected: $log_type."
sleep 1

# Prompt the user for the location of the device
read -p "Enter the server location: " device_location
device_location=${device_location// /_} # Replace spaces with underscores

# Create a new folder for the logs
new_folder="${device_location}_logs_$(date '+%Y_%m_%d')"
mkdir -p "$new_folder"

echo ""
echo "Collecting $log_type from $log_directory..."
sleep 1

# Collect logs based on the user's selection
if [[ "$log_choice" == "1" ]]; then
    # For V4 logs: Collect only access log files
    find "$log_directory" -type f -name "access.log*" -exec cp {} "$new_folder"/ \;
elif [[ "$log_choice" == "2" ]]; then
    # For V5 logs: Collect oc4d-*.log, capecoastcastle-*.log, and *.gz, excluding exceptions
    find "$log_directory" -type f \
        \( \
            \( -name "oc4d-*.log" ! -name "oc4d-exceptions-*.log" \) \
            -o \
            \( -name "capecoastcastle-*.log" ! -name "capecoastcastle-exceptions-*.log" \) \
            -o \
            -name "*.gz" \
        \) \
        -exec cp {} "$new_folder"/ \;
fi

# Move to the new folder
cd "$new_folder" || { echo "Failed to access the logs folder. Exiting..."; exit 1; }

# Uncompress any .gz files
echo "Uncompressing files (if any)..."
for compressed_file in *.gz; do
    if [ -f "$compressed_file" ]; then
        gzip -d "$compressed_file"
    fi
done

# Return to the original directory
cd ..

# Check if the "00_DATA" folder exists, and create it if not
if [ ! -d "00_DATA" ]; then
    mkdir "00_DATA"
fi

# Move the collected logs to the "00_DATA" directory
mv "$new_folder" "00_DATA"

echo ""
echo "Log collection completed successfully!"
echo "$log_type have been saved to the '00_DATA/$new_folder' directory."
echo ""

# Prompt the user to process the logs
while true; do
    read -p "Would you like to process the collected logs now? (y/n): " user_choice
    case $user_choice in
        [Yy]* )
            echo "Starting the log processing script..."
            sleep 1
            if [[ "$log_choice" == "1" ]]; then
                exec ./scripts/data/process/all.sh
            elif [[ "$log_choice" == "2" ]]; then
                exec ./scripts/data/all/v2/process/logs.sh
            fi
            break
            ;;
        [Nn]* )
            echo "Returning to the main menu..."
            sleep 1
            exec ./scripts/data/collection/main.sh
            break
            ;;
        * )
            echo "Please answer with 'y' (yes) or 'n' (no)."
            ;;
    esac
done
