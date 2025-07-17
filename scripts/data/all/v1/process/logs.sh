#!/bin/bash

# Define the Python script path
python_script_path="scripts/data/process/processors/log.py"

echo ""
# Prompt the user to pick a folder from '00_DATA' directory
echo "Select one of the available log folders in the '00_DATA' directory:"
folders=($(ls -d 00_DATA/*logs*/ 2>/dev/null))  # Filter folders with "logs" in their name

if [ ${#folders[@]} -eq 0 ]; then
    echo ""
    echo "No log folders found in '00_DATA'. Please ensure logs are available for processing."
    sleep 5
    exec ./scripts/data/process/main.sh
fi

for ((i=0; i<${#folders[@]}; i++)); do
    echo "$((i+1)). ${folders[i]#00_DATA/}"
done

# Prompt the user for their choice
echo ""
read -p "Enter the number corresponding to the log folder you want to process: " folder_number

# Validate user input
if [[ ! $folder_number =~ ^[1-9][0-9]*$ || $folder_number -gt ${#folders[@]} ]]; then
    echo "Invalid input. Please enter a valid folder number."
    sleep 3
    exec ./scripts/data/process/main.sh
fi

# Construct the full path to the selected folder
selected_folder=${folders[$((folder_number-1))]#00_DATA/}

# Confirm folder selection before processing
echo ""
read -p "You selected '${selected_folder}'. Press Enter to confirm and start processing..."

# Run the Python script with the selected folder as an argument
python3 "$python_script_path" "$selected_folder"

echo ""
echo "Processing completed."

# After all processing is complete, ask the user if they want to upload the data
echo ""
read -p "Do you want to upload the processed data? (y/n): " upload_choice

if [[ "$upload_choice" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Uploading data..."
    # Execute the upload script here
    exec ./scripts/data/upload/upload.sh
else
    echo ""
    echo "Upload skipped. Returning to the main menu."
    sleep 2
    exec ./scripts/data/main.sh
fi