#!/bin/bash

# --- Configuration ---
# The path to your live log file. UPDATE THIS PATH.
LOG_SOURCE_PATH="/home/llewellyn/Downloads/Anna-server_logs_2025_07_29"

# The path to the Python script.
PYTHON_SCRIPT_PATH="/home/llewellyn/Downloads/csv_row_remover.py"

# The directory to store the filtered logs.
PROCESSING_DIR="/home/llewellyn/filtered_logs"

# The criteria to remove from the logs.
CRITERIA="crypto"

# --- Script Logic ---

# Create the processing directory if it doesn't exist.
mkdir -p "$PROCESSING_DIR"

# Generate a unique filename with a timestamp.
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="$PROCESSING_DIR/logs_filtered_$TIMESTAMP.csv"

# Run the Python script to filter the logs.
python3 "$PYTHON_SCRIPT_PATH" "$LOG_SOURCE_PATH" "$OUTPUT_FILE" "$CRITERIA"

# Log the result.
echo "Filtered logs saved to $OUTPUT_FILE"

# Clean up old logs (e.g., older than 30 days) to save space.
find "$PROCESSING_DIR" -type f -name "*.csv" -mtime +30 -exec rm {} \;

echo "Log processing complete on $(date)."