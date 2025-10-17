#!/usr/bin/env python3

import sys
import os
import csv
from datetime import datetime

def process_csv(folder, location, month, processed_file_name):
    """
    Filters a CSV file to include only rows from a specific month and
    renames it to the format <location>_<MM>_<YYYY>.csv.
    """
    input_path = os.path.join(folder, processed_file_name)
    temp_output_path = os.path.join(folder, "temp_filtered.csv")
    header = None
    latest_year = None
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
                    # Assumes date is in row[1] in YYYY-MM-DD format
                    date_obj = datetime.strptime(row[1], '%Y-%m-%d')
                    if date_obj.month == month:
                        writer.writerow(row)
                        rows_written += 1
                        if latest_year is None or date_obj.year > latest_year:
                            latest_year = date_obj.year
                except (ValueError, IndexError):
                    continue  # Skip invalid or malformed rows

    except FileNotFoundError:
        sys.exit(f"Error: Input file not found at {input_path}")
    except Exception as e:
        sys.exit(f"Error processing CSV: {e}")

    if latest_year is None:
        print(f"No valid rows were found for month {month}.")
        os.remove(temp_output_path)
        # For manual script, output nothing so the calling script knows it failed.
        # For automation, the runner script will see no file was created.
        sys.exit(0) 

    # Final rename to match <name>_MM_YYYY.csv
    final_name = f"{location}_{month:02d}_{latest_year}.csv"
    final_path = os.path.join(folder, final_name)
    os.rename(temp_output_path, final_path)

    # Output the year for the calling script (used by manual upload.sh)
    print(latest_year)

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python process_csv.py <folder> <location> <month> <processed_file_name>")
        sys.exit(1)

    folder_arg = sys.argv[1]
    location_arg = sys.argv[2]
    try:
        month_arg = int(sys.argv[3])
        if not 1 <= month_arg <= 12:
            raise ValueError("Month must be between 1 and 12.")
    except (ValueError, IndexError) as e:
        print(f"Error: Invalid month provided. {e}")
        sys.exit(1)

    processed_file_name_arg = sys.argv[4]
    process_csv(folder_arg, location_arg, month_arg, processed_file_name_arg)
