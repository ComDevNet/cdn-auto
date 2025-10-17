#!/usr/bin/env python3

import sys
import os
import csv
from datetime import datetime, timedelta

def process_time_based_csv(folder, location, schedule_type):
    """
    Filters a summary.csv file based on a specified time interval (hourly, daily, weekly)
    and renames the output file according to the specified naming convention.
    """
    input_path = os.path.join(folder, "summary.csv")
    temp_output_path = os.path.join(folder, "temp_filtered.csv")
    
    if not os.path.exists(input_path):
        print(f"Error: summary.csv not found in {folder}")
        sys.exit(1)

    now = datetime.now()
    start_time = None

    if schedule_type == "hourly":
        start_time = now - timedelta(hours=1)
        file_timestamp = now.strftime("%H_%d_%m_%Y")
        output_filename = f"{location}_{file_timestamp}.csv"
    elif schedule_type == "daily":
        start_time = now.replace(hour=0, minute=0, second=0, microsecond=0)
        file_timestamp = now.strftime("%d_%m_%Y")
        output_filename = f"{location}_{file_timestamp}.csv"
    elif schedule_type == "weekly":
        start_of_week = now - timedelta(days=now.weekday())
        start_time = start_of_week.replace(hour=0, minute=0, second=0, microsecond=0)
        # WW format: Week number of the year
        file_timestamp = now.strftime("%W_%m_%Y")
        output_filename = f"{location}_{file_timestamp}.csv"
    else:
        print(f"Error: Invalid schedule type '{schedule_type}' provided.")
        sys.exit(1)

    final_output_path = os.path.join(folder, output_filename)
    rows_written = 0

    try:
        with open(input_path, 'r', newline='', encoding='utf-8') as infile, \
             open(temp_output_path, 'w', newline='', encoding='utf-8') as outfile:

            reader = csv.reader((line.replace('\0', '') for line in infile))
            writer = csv.writer(outfile)

            try:
                header = next(reader)
                writer.writerow(header)
            except StopIteration:
                print("Warning: summary.csv is empty.")
                sys.exit(0) # Exit gracefully if the input file is empty

            for row in reader:
                try:
                    # Expects date in col 2 (index 1) and time in col 3 (index 2)
                    row_date_str = row[1]
                    row_time_str = row[2] 
                    # Combine date and time string to create a datetime object
                    date_obj = datetime.strptime(f"{row_date_str} {row_time_str}", '%Y-%m-%d %H:%M:%S')
                    
                    # Check if the log entry's timestamp is within the desired time window
                    if date_obj >= start_time:
                        writer.writerow(row)
                        rows_written += 1
                except (ValueError, IndexError):
                    # This will skip rows with missing/malformed dates or times
                    continue

    except Exception as e:
        print(f"An error occurred during CSV processing: {e}")
        sys.exit(1)

    # Only create the final file if we actually found new data
    if rows_written > 0:
        os.rename(temp_output_path, final_output_path)
        print(f"Successfully created {output_filename} with {rows_written} new entries.")
    else:
        # If no new data, just clean up the temporary file
        os.remove(temp_output_path)
        print("No new log entries found for the selected time period.")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python filter_time_based.py <folder_path> <device_location> <schedule_type>")
        sys.exit(1)

    folder_path = sys.argv[1]
    device_location = sys.argv[2]
    schedule = sys.argv[3]
    
    process_time_based_csv(folder_path, device_location, schedule)

