#!/bin/bash

echo ""
echo "Collecting Log Files (Server v6)"
echo ""

# Prompt the user for the location of the device
read -p "Enter the location of the device: " device_location
# Replace spaces with underscores
device_location=${device_location// /_}

# Specify the log directory for Server v6
log_directory="/var/log/v6"

# Create a new folder with location and timestamp
new_folder="${device_location}_logs_$(date '+%Y_%m_%d')"
mkdir -p "$new_folder"

# Copy only relevant log files from v6 logs
find "$log_directory" -type f \
    \( \
        -name "*.log" \
        -o \
        -name "*.gz" \
    \) \
    -exec cp {} "$new_folder"/ \;

# Move to the new folder
cd "$new_folder" || exit

# Uncompress all gzipped log files (if any exist)
for compressed_file in *.gz; do
    if [ -f "$compressed_file" ]; then
        gzip -d "$compressed_file"
    fi
done

# Move back to the original directory
cd ..

# Check if the "00_DATA" folder exists, and create it if not
if [ ! -d "00_DATA" ]; then
    mkdir "00_DATA"
fi

# Move the new folder to the "00_DATA" directory
mv "$new_folder" "00_DATA"

# Display a message about the completed operation
echo "Logs are ready in the 00_DATA directory."
echo ""

# Prompt to start log processing
read -p "Press Enter to start log file processing..."

# Start log processing
exec ./scripts/data/all/v3/process/logs.sh
