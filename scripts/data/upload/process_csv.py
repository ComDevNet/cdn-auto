#!/usr/bin/env python3

import sys
import os
import csv
from datetime import datetime, timedelta

def column_index(header, column_name, fallback=None):
    normalized = [value.strip().lower() for value in header]
    try:
        return normalized.index(column_name.strip().lower())
    except ValueError:
        return fallback


def process_csv(folder, location, month, processed_file_name, mode='year', suffix='access_logs'):
    """
    Filters a CSV for a specific month.
    - In 'year' mode (default, for manual upload), it prints the year.
    - In 'filename' mode (for automation), it prints the final filename.
    
    For automation (mode='filename'), if month is negative, it calculates the previous month.
    """
    input_path = os.path.join(folder, processed_file_name)
    temp_output_path = os.path.join(folder, "temp_filtered.csv")
    header = None
    latest_year = None
    rows_written = 0

    # Handle previous month calculation for automation
    if month < 1:
        # Calculate previous month
        today = datetime.now()
        first_day_this_month = today.replace(day=1)
        last_day_prev_month = first_day_this_month - timedelta(days=1)
        month = last_day_prev_month.month
        sys.stderr.write(f"📊 Filtering logs for: {last_day_prev_month.strftime('%B %Y')} (previous month)\n")
    else:
        sys.stderr.write(f"📊 Filtering logs for: Month {month}\n")
    
    try:
        with open(input_path, 'r', newline='', encoding='utf-8') as infile, \
             open(temp_output_path, 'w', newline='', encoding='utf-8') as outfile:

            reader = csv.reader((line.replace('\0', '') for line in infile))
            writer = csv.writer(outfile)

            try:
                header = next(reader)
                writer.writerow(header)
                date_index = column_index(header, "Access Date", 1)
            except StopIteration:
                sys.exit(0) # Exit gracefully if empty, printing nothing

            for row in reader:
                try:
                    date_obj = datetime.strptime(row[date_index], '%Y-%m-%d')
                    if date_obj.month == month:
                        writer.writerow(row)
                        rows_written += 1
                        if latest_year is None or date_obj.year > latest_year:
                            latest_year = date_obj.year
                except Exception:
                    continue  # Skip invalid rows

    except Exception as e:
        # Send errors to stderr so they don't get captured by runner.sh
        sys.stderr.write(f"Error processing CSV: {e}\n")
        sys.exit(1)

    if rows_written == 0:
        os.remove(temp_output_path)
        sys.stderr.write(f"⚠️  No log entries found for this period\n")
        # Print nothing if no file was created
        sys.exit(0)

    # Final rename
    final_name = f"{location}_{month:02d}_{latest_year}_{suffix}.csv"
    final_path = os.path.join(folder, final_name)
    os.rename(temp_output_path, final_path)
    sys.stderr.write(f"✅ Found {rows_written} log entries for uploading\n")

    if mode == 'filename':
        print(final_name)
    else:
        print(latest_year)

if __name__ == "__main__":
    if len(sys.argv) not in [5, 6, 7]:
        sys.stderr.write("Usage: python process_csv.py <folder> <location> <month> <processed_file_name> [mode] [suffix]\n")
        sys.exit(1)

    folder = sys.argv[1]
    location = sys.argv[2]
    try:
        month = int(sys.argv[3])
        # Allow 0 for automation (previous month calculation) or 1-12 for manual
        if not (month == 0 or 1 <= month <= 12):
            raise ValueError
    except ValueError:
        sys.stderr.write("Error: Month must be 0 (for previous month) or an integer between 1 and 12.\n")
        sys.exit(1)

    processed_file_name = sys.argv[4]
    # Determine mode for output
    mode = 'year'
    if len(sys.argv) == 6 and sys.argv[5] == 'filename':
        mode = 'filename'
    elif len(sys.argv) == 6 and sys.argv[5] == 'year':
        mode = 'year'

    suffix = 'access_logs'
    if len(sys.argv) == 7:
        if sys.argv[5] in ('year', 'filename'):
            mode = sys.argv[5]
        suffix = sys.argv[6]
        
    process_csv(folder, location, month, processed_file_name, mode, suffix)

