#!/usr/bin/env python3

import sys
import os
import csv
from datetime import datetime, timedelta, time

def process_time_based_csv(folder, location, schedule_type):
    """
    Filters a summary.csv file for the last *completed* time interval (hour, day, week)
    and renames the output file according to the specified naming convention.
    Prints the final filename to stdout on success.
    """
    input_path = os.path.join(folder, "summary.csv")
    temp_output_path = os.path.join(folder, "temp_filtered.csv")
    
    if not os.path.exists(input_path):
        sys.stderr.write(f"Error: summary.csv not found in {folder}\n")
        sys.exit(1)

    now = datetime.now()
    start_time = None
    end_time = None
    file_timestamp_dt = None

    if schedule_type == "hourly":
        # Target the previous hour
        target_hour_dt = now - timedelta(hours=1)
        start_time = target_hour_dt.replace(minute=0, second=0, microsecond=0)
        end_time = start_time.replace(minute=59, second=59, microsecond=999999)
        file_timestamp_dt = target_hour_dt
        file_timestamp = file_timestamp_dt.strftime("%H_%d_%m_%Y")
        output_filename = f"{location}_{file_timestamp}_access_logs.csv"

    elif schedule_type == "daily":
        # Target yesterday
        yesterday_dt = now - timedelta(days=1)
        start_time = datetime.combine(yesterday_dt.date(), time.min)
        end_time = datetime.combine(yesterday_dt.date(), time.max)
        file_timestamp_dt = yesterday_dt
        file_timestamp = file_timestamp_dt.strftime("%d_%m_%Y")
        output_filename = f"{location}_{file_timestamp}_access_logs.csv"

    elif schedule_type == "weekly":
        # Target the previous full week (last Monday to last Sunday)
        today = now.date()
        start_of_this_week = today - timedelta(days=today.weekday())
        start_of_last_week = start_of_this_week - timedelta(weeks=1)
        end_of_last_week = start_of_last_week + timedelta(days=6)
        
        start_time = datetime.combine(start_of_last_week, time.min)
        end_time = datetime.combine(end_of_last_week, time.max)
        file_timestamp_dt = start_of_last_week
        # Use the week number (and year) of the processed week for the filename
        file_timestamp = file_timestamp_dt.strftime("%W_%m_%Y")
        output_filename = f"{location}_{file_timestamp}_access_logs.csv"
        
    else:
        sys.stderr.write(f"Error: Invalid schedule type '{schedule_type}' provided.\n")
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
                sys.exit(0)

            for row in reader:
                try:
                    row_date_str = row[1]
                    # Check if Access Time (column 2) exists; if not, use midnight
                    if len(row) > 2 and row[2]:
                        row_time_str = row[2]
                    else:
                        row_time_str = "00:00:00"  # Default to midnight if no time available
                    
                    date_obj = datetime.strptime(f"{row_date_str} {row_time_str}", '%Y-%m-%d %H:%M:%S')
                    
                    # Check if the log entry's timestamp is within the target window
                    if start_time <= date_obj <= end_time:
                        writer.writerow(row)
                        rows_written += 1
                except (ValueError, IndexError):
                    continue

    except Exception as e:
        sys.stderr.write(f"An error occurred during CSV processing: {e}\n")
        sys.exit(1)

    if rows_written > 0:
        os.rename(temp_output_path, final_output_path)
        print(output_filename)
    else:
        os.remove(temp_output_path)

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.stderr.write("Usage: python filter_time_based.py <folder_path> <device_location> <schedule_type>\n")
        sys.exit(1)

    folder_path = sys.argv[1]
    device_location = sys.argv[2]
    schedule = sys.argv[3]
    
    process_time_based_csv(folder_path, device_location, schedule)

