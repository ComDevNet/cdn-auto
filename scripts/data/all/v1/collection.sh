#!/bin/bash

echo ""
echo "Collecting Log Files"
echo ""

# Prompt the user for the location of the device
read -p "Enter the location of the device: " device_location
# Replace spaces with underscores
device_location=${device_location// /_}

# Specify the log directory
log_directory="/var/log/apache2"

# Create a new folder with location and timestamp
new_folder="${device_location}_logs_$(date '+%Y_%m_%d')"
mkdir "$new_folder"

# Copy only access log files to the new folder
find "$log_directory" -type f -name "access.log*" -exec cp {} "$new_folder"/ \;

# Move to the new folder
cd "$new_folder" || exit

# Uncompress all individual log files
for compressed_file in *.gz; do
    gzip -d "$compressed_file"
done

# Rename files based on the date in the first line
for file in *; do
    if [ -f "$file" ]; then
        # Extract the day, month, and year from the first line of the file
        first_line_date=$(head -n 1 "$file" | grep -oP '\[\K[0-9]{2}/[a-zA-Z]+/[0-9]{4}')
        
        # Replace slashes with underscores for a valid filename
        formatted_date=$(echo "$first_line_date" | tr '/' '_')
        
        # Remove numbers and the preceding full stop at the end of the filename
        new_filename=$(echo "$formatted_date"_"$file" | sed 's/\.[0-9]\+$//')
        
        # Rename the file
        mv "$file" "$new_filename"
    fi
done

# Move back to the original directory
cd ..

# Check if the "00_DATA" folder exists, and create it if not
if [ ! -d "00_DATA" ]; then
    mkdir "00_DATA"
fi

# Move the log folder to the "00_DATA" directory
mv "$new_folder" "00_DATA"

# Display a completion message
echo "Logs are ready in the 00_DATA directory."
echo ""

# Wait for user input before starting processing
read -p "Press Enter to start log file processing..."

# Start log processing
exec ./scripts/data/all/v1/process/logs.sh
