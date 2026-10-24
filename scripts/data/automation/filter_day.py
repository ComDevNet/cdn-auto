#!/usr/bin/env python3
"""Filter summary.csv to a single calendar day; print the output basename on success.

Used by backfill_s3_days.sh so near_realtime devices can re-export past days
that the rolling today→now harvest will never touch again.
"""

from __future__ import annotations

import csv
import os
import sys
from datetime import datetime


def column_index(header, column_name, fallback=None):
    normalized = [value.strip().lower() for value in header]
    try:
        return normalized.index(column_name.strip().lower())
    except ValueError:
        return fallback


def filter_day(folder: str, location: str, day: str, suffix: str = "access_logs") -> str | None:
    input_path = os.path.join(folder, "summary.csv")
    if not os.path.exists(input_path):
        sys.stderr.write(f"Error: summary.csv not found in {folder}\n")
        sys.exit(1)

    try:
        start = datetime.strptime(f"{day} 00:00:00", "%Y-%m-%d %H:%M:%S")
        end = datetime.strptime(f"{day} 23:59:59", "%Y-%m-%d %H:%M:%S")
    except ValueError as exc:
        sys.stderr.write(f"Invalid day '{day}' (want YYYY-MM-DD): {exc}\n")
        sys.exit(1)

    # Match schedule_type=daily stamp: location_DD_MM_YYYY_suffix.csv
    dd, mm, yyyy = day[8:10], day[5:7], day[0:4]
    out_name = f"{location}_{dd}_{mm}_{yyyy}_{suffix}.csv"
    out_path = os.path.join(folder, out_name)
    tmp_path = out_path + ".tmp"

    rows_written = 0
    try:
        with open(input_path, "r", newline="", encoding="utf-8") as infile, open(
            tmp_path, "w", newline="", encoding="utf-8"
        ) as outfile:
            reader = csv.reader((line.replace("\0", "") for line in infile))
            writer = csv.writer(outfile)
            try:
                header = next(reader)
            except StopIteration:
                os.remove(tmp_path)
                return None
            writer.writerow(header)
            date_index = column_index(header, "Access Date", 1)
            time_index = column_index(header, "Access Time")

            for row in reader:
                try:
                    row_date_str = row[date_index]
                    if time_index is not None and len(row) > time_index and row[time_index]:
                        try:
                            date_time_obj = datetime.strptime(
                                f"{row_date_str} {row[time_index]}", "%Y-%m-%d %H:%M:%S"
                            )
                        except (ValueError, IndexError):
                            date_time_obj = datetime.strptime(row_date_str, "%Y-%m-%d")
                    else:
                        date_time_obj = datetime.strptime(row_date_str, "%Y-%m-%d")
                    if start <= date_time_obj <= end:
                        writer.writerow(row)
                        rows_written += 1
                except (ValueError, IndexError):
                    continue
    except OSError as exc:
        sys.stderr.write(f"Error filtering day CSV: {exc}\n")
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        sys.exit(1)

    if rows_written == 0:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        sys.stderr.write(f"No log entries for {day}\n")
        return None

    os.replace(tmp_path, out_path)
    sys.stderr.write(f"Wrote {rows_written} rows -> {out_name}\n")
    return out_name


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.stderr.write(
            "Usage: python filter_day.py <folder_path> <device_location> <YYYY-MM-DD> [suffix]\n"
        )
        sys.exit(1)

    suffix = sys.argv[4] if len(sys.argv) == 5 and sys.argv[4] else "access_logs"
    name = filter_day(sys.argv[1], sys.argv[2], sys.argv[3], suffix=suffix)
    if name:
        print(name)
    else:
        sys.exit(2)
