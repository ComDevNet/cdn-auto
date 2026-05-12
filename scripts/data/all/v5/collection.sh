#!/bin/bash

echo "Collecting ModuleGaze Log Files"

read -p "Enter the location of the device: " device_location
device_location=${device_location// /_}

log_directory="/var/log/modulegaze"
new_folder="${device_location}_modulegaze_logs_$(date '+%Y_%m_%d')"
mkdir -p "$new_folder"

echo "Collecting ModuleGaze logs from $log_directory..."
find "$log_directory" -type f \
    \( \
        -name "modulegaze-sessions.log" \
        -o \
        -name "modulegaze-sessions-*.log.zip" \
    \) \
    -exec cp {} "$new_folder"/ \;

if [ ! -d "00_DATA" ]; then
    mkdir "00_DATA"
fi

mv "$new_folder" "00_DATA"

echo ""
echo "Log collection completed successfully!"
echo "ModuleGaze logs have been saved to the '00_DATA/$new_folder' directory."
echo ""

read -p "Press Enter to start log file processing..."
exec ./scripts/data/all/v5/process/logs.sh
