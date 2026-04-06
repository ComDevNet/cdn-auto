#!/usr/bin/env python3

import csv
import os
import sys
from datetime import datetime

from time_window import build_filename, compute_window


def process_time_based_csv(folder, location, schedule_type, run_interval_seconds=None):
    """
    Filters summary.csv for the last completed interval and prints the final filename on success.
    """
    input_path = os.path.join(folder, "summary.csv")
    temp_output_path = os.path.join(folder, "temp_filtered.csv")

    if not os.path.exists(input_path):
        sys.stderr.write(f"Error: summary.csv not found in {folder}\n")
        sys.exit(1)

    try:
        window = compute_window(schedule_type, run_interval_seconds=run_interval_seconds)
    except ValueError as exc:
        sys.stderr.write(f"{exc}\n")
        sys.exit(1)

    start_time = window.start
    end_time = window.end
    output_filename = build_filename(location, schedule_type, "access_logs", window=window)

    sys.stderr.write(f"Filtering logs for: {window.label}\n")

    final_output_path = os.path.join(folder, output_filename)
    rows_written = 0

    try:
        with open(input_path, "r", newline="", encoding="utf-8") as infile, open(
            temp_output_path, "w", newline="", encoding="utf-8"
        ) as outfile:
            reader = csv.reader((line.replace("\0", "") for line in infile))
            writer = csv.writer(outfile)

            try:
                header = next(reader)
                writer.writerow(header)
            except StopIteration:
                sys.exit(0)

            for row in reader:
                try:
                    row_date_str = row[1]
                    if len(row) > 2 and row[2]:
                        try:
                            row_time_str = row[2]
                            date_time_obj = datetime.strptime(
                                f"{row_date_str} {row_time_str}", "%Y-%m-%d %H:%M:%S"
                            )
                        except (ValueError, IndexError):
                            date_time_obj = datetime.strptime(row_date_str, "%Y-%m-%d")
                    else:
                        date_time_obj = datetime.strptime(row_date_str, "%Y-%m-%d")

                    if start_time <= date_time_obj <= end_time:
                        writer.writerow(row)
                        rows_written += 1
                except (ValueError, IndexError):
                    continue
    except Exception as exc:
        sys.stderr.write(f"An error occurred during CSV processing: {exc}\n")
        sys.exit(1)

    if rows_written > 0:
        os.rename(temp_output_path, final_output_path)
        sys.stderr.write(f"Found {rows_written} log entries for uploading\n")
        print(output_filename)
    else:
        os.remove(temp_output_path)
        sys.stderr.write("No log entries found for this period\n")


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.stderr.write(
            "Usage: python filter_time_based.py <folder_path> <device_location> <schedule_type> [run_interval_seconds]\n"
        )
        sys.exit(1)

    run_interval_seconds = None
    if len(sys.argv) == 5 and sys.argv[4]:
        try:
            run_interval_seconds = int(sys.argv[4])
        except ValueError:
            sys.stderr.write("Error: run_interval_seconds must be an integer.\n")
            sys.exit(1)

    process_time_based_csv(sys.argv[1], sys.argv[2], sys.argv[3], run_interval_seconds=run_interval_seconds)
