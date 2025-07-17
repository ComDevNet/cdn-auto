#!/usr/bin/env python3

import sys
import os
import csv
from datetime import datetime

def process_csv(folder, location, month, processed_file_name):
    input_path = os.path.join(folder, processed_file_name)
    temp_output_path = os.path.join(folder, "temp_filtered.csv")
    header = None
    latest_year = None

    try:
        with open(input_path, 'r', newline='', encoding='utf-8') as infile, \
             open(temp_output_path, 'w', newline='', encoding='utf-8') as outfile:

            reader = csv.reader((line.replace('\0', '') for line in infile))
            writer = csv.writer(outfile)

            header = next(reader)
            writer.writerow(header)

            for row in reader:
                try:
                    date_obj = datetime.strptime(row[1], '%Y-%m-%d')
                    if date_obj.month == month:
                        writer.writerow(row)
                        if latest_year is None or date_obj.year > latest_year:
                            latest_year = date_obj.year
                except Exception:
                    continue  # Skip invalid rows

    except Exception as e:
        sys.exit(f"Error processing CSV: {e}")

    if latest_year is None:
        print("No valid rows matched.")
        sys.exit(1)

    # Final rename
    final_name = f"{location}_{month:02d}_{latest_year}_access_logs.csv"
    final_path = os.path.join(folder, final_name)
    os.rename(temp_output_path, final_path)

    print(latest_year)

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python process_csv.py <folder> <location> <month> <processed_file_name>")
        sys.exit(1)

    folder = sys.argv[1]
    location = sys.argv[2]
    try:
        month = int(sys.argv[3])
        if not 1 <= month <= 12:
            raise ValueError
    except ValueError:
        print("Error: Month must be an integer between 1 and 12.")
        sys.exit(1)

    processed_file_name = sys.argv[4]
    process_csv(folder, location, month, processed_file_name)
