#!/bin/bash

# Script descriptions
script1="V1 - For everyday Rachel Logs" 
script2="V2 - For Cape Coast Castle Logs"

# Display options with descriptions
echo ""
echo "Choose a Python script to run:"
echo ""
echo "1. $script1"
echo "2. $script2"
echo ""

read -p "Enter the number corresponding to the script you want to run: " script_number

# Validate user input
if [[ ! $script_number =~ ^[1-2]$ ]]; then
    echo "Invalid input. Please enter a valid script number."
    sleep 3
    exec ./scripts/data/process/main.sh
fi

# Set the path to the selected Python script
if [ "$script_number" == "1" ]; then
  python_script_path="scripts/data/process/processors/log.py"
elif [ "$script_number" == "2" ]; then  
  python_script_path="scripts/data/process/processors/logv2.py"
fi

# Prompt the user to pick a folder from '00_DATA' directory
echo "Available log folders in '00_DATA' directory:"
folders=($(ls -d 00_DATA/*logs*/))  # Filter folders with "logs" in their name

if [ ${#folders[@]} -eq 0 ]; then
    echo "No log folders found in '00_DATA'. Exiting..."
    sleep 5
    exec ./scripts/data/process/main.sh
fi

for ((i=0; i<${#folders[@]}; i++)); do
    echo "$((i+1)). ${folders[i]#00_DATA/}"
done

# Prompt the user for their choice
read -p "Enter the number corresponding to the log folder you want to process: " folder_number

# Validate user input
if [[ ! $folder_number =~ ^[1-9][0-9]*$ || $folder_number -gt ${#folders[@]} ]]; then
    echo "Invalid input. Please enter a valid folder number."
    sleep 5
    exec ./scripts/data/process/main.sh
fi

# Construct the full path to the selected folder
selected_folder=${folders[$((folder_number-1))]#00_DATA/}

# Run the Python script with the selected folder as an argument
python3 "$python_script_path" "$selected_folder"

echo "Processing requests Request file"
    exec ./scripts/data/process/all/requests.sh

