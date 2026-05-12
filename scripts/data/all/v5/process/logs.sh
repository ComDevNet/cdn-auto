#!/bin/bash

python_script_path="scripts/data/process/processors/modulegaze.py"

echo ""
echo "Select one of the available ModuleGaze log folders in the '00_DATA' directory:"
folders=($(ls -d 00_DATA/*modulegaze*logs*/ 2>/dev/null))

if [ ${#folders[@]} -eq 0 ]; then
    echo ""
    echo "No ModuleGaze log folders found in '00_DATA'. Please ensure logs are available for processing."
    sleep 5
    exec ./scripts/data/process/main.sh
fi

for ((i=0; i<${#folders[@]}; i++)); do
    echo "$((i+1)). ${folders[i]#00_DATA/}"
done

echo ""
read -p "Enter the number corresponding to the ModuleGaze log folder you want to process: " folder_number

if [[ ! $folder_number =~ ^[1-9][0-9]*$ || $folder_number -gt ${#folders[@]} ]]; then
    echo "Invalid input. Please enter a valid folder number."
    sleep 3
    exec ./scripts/data/process/main.sh
fi

selected_folder=${folders[$((folder_number-1))]#00_DATA/}

echo ""
read -p "You selected '${selected_folder}'. Press Enter to confirm and start processing..."

python3 "$python_script_path" "$selected_folder"

echo ""
echo "Processing completed."
echo ""
read -p "Do you want to upload the processed ModuleGaze data? (y/n): " upload_choice

if [[ "$upload_choice" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Uploading ModuleGaze data..."
    exec ./scripts/data/upload/modulegaze.sh
else
    echo ""
    echo "Upload skipped. Returning to the main menu."
    sleep 2
    exec ./scripts/data/main.sh
fi
