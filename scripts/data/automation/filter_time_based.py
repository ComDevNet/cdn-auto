#!/usr/bin/env python3

import sys
import os
import csv
from datetime import datetime, timedelta

def filter_and_rename(folder, location, schedule, input_file):
    """
    Filters a CSV file based on a time interval (hourly, daily, weekly)
    and renames it according to the specified convention.
    """
    input_path = os.path.join(folder, input_file)
    temp_output_path = os.path.join(folder, "temp_filtered_time_based.csv")
    
    now = datetime.now()
    header = None
    rows_written = 0

    try:
        with open(input_path, 'r', newline='', encoding='utf-8') as infile, \
             open(temp_output_path, 'w', newline='', encoding='utf-8') as outfile:

            reader = csv.reader((line.replace('\0', '') for line in infile))
            writer = csv.writer(outfile)
            header = next(reader)
            writer.writerow(header)

            for row in reader:
                try:
                    # Assumes date is in row[1] (YYYY-MM-DD) and time is in row[2] (HH:MM:SS)
                    # This is an assumption to fulfill the hourly requirement.
                    # If time is not present, hourly filtering will not find any matches.
                    row_date_str = row[1]
                    row_time_str = row[2]
                    date_obj = datetime.strptime(f"{row_date_str} {row_time_str}", '%Y-%m-%d %H:%M:%S')

                    should_write = False
                    if schedule == 'hourly':
                        one_hour_ago = now - timedelta(hours=1)
                        if date_obj >= one_hour_ago:
                            should_write = True
                    elif schedule == 'daily':
                        if date_obj.date() == now.date():
                            should_write = True
                    elif schedule == 'weekly':
                        # Monday is 0 and Sunday is 6.
                        # This finds the start of the current week (last Monday).
                        start_of_week = now.date() - timedelta(days=now.weekday())
                        if date_obj.date() >= start_of_week:
                             should_write = True
                    
                    if should_write:
                        writer.writerow(row)
                        rows_written += 1

                except (ValueError, IndexError):
                    # Skip rows with invalid date/time format or missing columns
                    continue

    except FileNotFoundError:
        sys.exit(f"Error: Input file not found at {input_path}")
    except Exception as e:
        sys.exit(f"Error processing CSV for time-based filtering: {e}")

    if rows_written == 0:
        print(f"No new log entries found for the '{schedule}' schedule.")
        os.remove(temp_output_path)
        sys.exit(0) # Exit gracefully, not an error
        
    # Naming convention logic
    final_name = ""
    if schedule == 'hourly':
        # Format: <name>_HH_DD_MM_YYYY.csv
        final_name = f"{location}_{now.strftime('%H_%d_%m_%Y')}.csv"
    elif schedule == 'daily':
        # Format: <name>_DD_MM_YYYY.csv
        final_name = f"{location}_{now.strftime('%d_%m_%Y')}.csv"
    elif schedule == 'weekly':
        # Format: <name>_WW_MM_YYYY.csv
        week_number = now.strftime('%W') # Week num (00-53), Monday is first day
        final_name = f"{location}_{week_number}_{now.strftime('%m_%Y')}.csv"
        
    if final_name:
        final_path = os.path.join(folder, final_name)
        os.rename(temp_output_path, final_path)
        print(f"Successfully created {final_name} with {rows_written} entries.")
    else:
        # This case should not be reached if schedule is validated before calling
        os.remove(temp_output_path)
        sys.exit("Error: Invalid schedule type for renaming.")

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python filter_time_based.py <folder> <location> <schedule> <input_file>")
        sys.exit(1)

    folder = sys.argv[1]
    location = sys.argv[2]
    schedule = sys.argv[3]
    input_file = sys.argv[4]
    
    if schedule not in ['hourly', 'daily', 'weekly']:
        print("Error: Schedule must be 'hourly', 'daily', or 'weekly'.")
        sys.exit(1)

    filter_and_rename(folder, location, schedule, input_file)
