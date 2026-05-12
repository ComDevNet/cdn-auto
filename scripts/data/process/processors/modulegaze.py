#!/usr/bin/env python3

import csv
import os
import sys
import zipfile
from datetime import datetime


HEADER = [
    "User",
    "Access Time",
    "IP Address",
    "Access Date",
    "Module Viewed",
    "Duration Seconds",
]


def parse_timestamp(value):
    value = value.strip()
    formats = [
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
    ]
    for fmt in formats:
        try:
            parsed = datetime.strptime(value, fmt)
            return parsed.replace(tzinfo=None)
        except ValueError:
            continue
    raise ValueError(f"Unsupported timestamp: {value}")


def normalize_ip(ip):
    if ip.startswith("::ffff:"):
        return ip[7:]
    return ip


def iter_text_lines(file_path):
    if file_path.endswith(".zip"):
        with zipfile.ZipFile(file_path) as archive:
            for name in archive.namelist():
                if not name.endswith(".log"):
                    continue
                with archive.open(name) as handle:
                    for raw_line in handle:
                        yield raw_line.decode("utf-8", "replace")
        return

    with open(file_path, "r", encoding="utf-8", errors="replace") as handle:
        yield from handle


def parse_session_line(line):
    parts = line.strip().split("\t")
    if len(parts) < 4:
        return None

    try:
        timestamp = parse_timestamp(parts[0])
    except ValueError:
        return None

    fields = {}
    for part in parts[1:]:
        if "=" in part:
            key, value = part.split("=", 1)
            fields[key] = value

    user_id = fields.get("userId", "Guest")
    ip = ""
    if "|" in user_id:
        user_id, ip = user_id.rsplit("|", 1)

    return [
        user_id or "Guest",
        timestamp.strftime("%H:%M:%S"),
        normalize_ip(ip),
        timestamp.strftime("%Y-%m-%d"),
        fields.get("moduleId", "none"),
        fields.get("durationSeconds", ""),
    ]


def process_log_file(file_path):
    log_data = []
    skipped_count = 0
    source_log = os.path.basename(file_path)

    for line in iter_text_lines(file_path):
        try:
            row = parse_session_line(line)
            if row:
                log_data.append(row)
            else:
                skipped_count += 1
        except Exception as exc:
            skipped_count += 1
            if skipped_count <= 3:
                print(f"Skipping line in {source_log}: {exc}")

    print(f"Processed {source_log}: {len(log_data)} rows, {skipped_count} skipped")
    return log_data


def clear_csv_outputs(folder_path):
    if not os.path.isdir(folder_path):
        return
    for root, _, files in os.walk(folder_path):
        for file in files:
            if file.endswith(".csv"):
                os.remove(os.path.join(root, file))


def save_processed_log_file(folder_path, file_path, log_data):
    os.makedirs(folder_path, exist_ok=True)
    base_name = os.path.basename(file_path)
    if base_name.endswith(".zip"):
        base_name = base_name[:-4]
    processed_file_path = os.path.join(folder_path, f"{os.path.splitext(base_name)[0]}.csv")

    with open(processed_file_path, "w", encoding="utf-8", newline="") as output_file:
        writer = csv.writer(output_file)
        writer.writerow(HEADER)
        writer.writerows(log_data)


def create_master_csv(folder_path):
    master_csv_path = os.path.join(folder_path, "summary.csv")
    os.makedirs(folder_path, exist_ok=True)

    with open(master_csv_path, "w", encoding="utf-8", newline="") as master_csv:
        writer = csv.writer(master_csv)
        writer.writerow(HEADER)
        for root, _, files in os.walk(folder_path):
            for file in sorted(files):
                if not file.endswith(".csv") or file == "summary.csv":
                    continue
                with open(os.path.join(root, file), "r", encoding="utf-8") as csv_file:
                    reader = csv.reader(csv_file)
                    next(reader, None)
                    writer.writerows(reader)


def is_processable(file_name):
    return (
        file_name == "modulegaze-sessions.log"
        or file_name.startswith("modulegaze-sessions-")
    ) and (
        file_name.endswith(".log")
        or file_name.endswith(".log.zip")
        or file_name.endswith(".zip")
    )


if __name__ == "__main__":
    selected_folder = sys.argv[1]
    folder_path = os.path.join("00_DATA", selected_folder)
    processed_folder_path = os.path.join("00_DATA", "00_PROCESSED", selected_folder)

    if not os.path.exists(folder_path):
        print(f"Error: Folder '{folder_path}' does not exist.")
        sys.exit(1)

    files_to_process = []
    for root, _, files in os.walk(folder_path):
        for file in files:
            if is_processable(file):
                files_to_process.append(os.path.join(root, file))

    clear_csv_outputs(processed_folder_path)

    total_files = len(files_to_process)
    if total_files == 0:
        print(f"No ModuleGaze session log files found in {folder_path}.")

    for index, file_path in enumerate(sorted(files_to_process), start=1):
        log_data = process_log_file(file_path)
        save_processed_log_file(processed_folder_path, file_path, log_data)
        print(f"Processing files: {index}/{total_files}")

    create_master_csv(processed_folder_path)
    print("Processing completed. All ModuleGaze session log files have been processed.")
