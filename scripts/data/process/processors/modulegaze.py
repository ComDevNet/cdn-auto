#!/usr/bin/env python3

import csv
import os
import re
import sys
import zipfile
from datetime import datetime
from urllib.parse import unquote, urlsplit

from user_agents import parse


HEADER = [
    "Log Type",
    "IP Address",
    "Access Date",
    "Access Time",
    "User",
    "Module Viewed",
    "Status Code",
    "Data Saved (GB)",
    "Device Used",
    "Browser Used",
    "Duration Seconds",
    "Schema Version",
    "Source Log",
]

ACCESS_PATTERN = re.compile(
    r"(?P<ip>(?:\d{1,3}\.){3}\d{1,3}|::ffff:(?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:.]+)"
    r"\s+(?:user=(?P<user>\S+)\s+)?-\s(?:-\s)?\["
    r"(?P<timestamp>[^\]]+)\]\s\""
    r"(?P<request>GET|POST|HEAD|PUT|DELETE|OPTIONS)\s"
    r"(?P<path>[^\s]+)\sHTTP/[0-9.]+\"\s"
    r"(?P<status_code>\d+|-)\s"
    r"(?P<size>\d+|-)\s"
    r"\"(?P<referrer>[^\"]*)\"\s"
    r"\"(?P<user_agent>[^\"]*)\""
)


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


def module_from_path(path):
    clean_path = unquote(urlsplit(path).path)
    patterns = [
        "/uploads/modules/",
        "/modules/",
        "/uploads/other-modules/",
    ]

    for marker in patterns:
        if marker not in clean_path:
            continue
        parts = [part for part in clean_path.split(marker, 1)[1].split("/") if part]
        if marker == "/uploads/other-modules/":
            return parts[0] if parts else "none"
        if len(parts) >= 2:
            return parts[1]
        if parts:
            return parts[0]

    return "none"


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


def parse_access_line(line, source_log):
    # Active modulegaze logs prepend an ingest timestamp and a tab before the
    # original oc4d journal line. Archived logs may contain either shape.
    message = line.rstrip("\n")
    if "\t" in message:
        message = message.split("\t", 1)[1]

    match = ACCESS_PATTERN.search(message)
    if not match:
        return None

    values = match.groupdict()
    timestamp = parse_timestamp(values["timestamp"])
    user_agent = parse(values["user_agent"])
    raw_size = values["size"]
    size_bytes = int(raw_size) if raw_size.isdigit() else 0

    return [
        "access",
        normalize_ip(values["ip"]),
        timestamp.strftime("%Y-%m-%d"),
        timestamp.strftime("%H:%M:%S"),
        values.get("user") or "Guest",
        module_from_path(values["path"]),
        values["status_code"],
        f"{size_bytes / 1073741824:.10f}",
        user_agent.os.family or "unknown",
        user_agent.browser.family or "unknown",
        "",
        "",
        source_log,
    ]


def parse_session_line(line, source_log):
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
        "session",
        normalize_ip(ip),
        timestamp.strftime("%Y-%m-%d"),
        timestamp.strftime("%H:%M:%S"),
        user_id or "Guest",
        fields.get("moduleId", "none"),
        "",
        "",
        "",
        "",
        fields.get("durationSeconds", ""),
        fields.get("schemaVersion", ""),
        source_log,
    ]


def process_log_file(file_path):
    log_data = []
    skipped_count = 0
    source_log = os.path.basename(file_path)
    is_session_log = "sessions" in source_log

    for line in iter_text_lines(file_path):
        try:
            row = (
                parse_session_line(line, source_log)
                if is_session_log
                else parse_access_line(line, source_log)
            )
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
        file_name.endswith(".log")
        or file_name.endswith(".log.zip")
        or file_name.endswith(".zip")
    ) and file_name.startswith("modulegaze-")


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

    total_files = len(files_to_process)
    if total_files == 0:
        print(f"No ModuleGaze log files found in {folder_path}.")

    for index, file_path in enumerate(sorted(files_to_process), start=1):
        log_data = process_log_file(file_path)
        save_processed_log_file(processed_folder_path, file_path, log_data)
        print(f"Processing files: {index}/{total_files}")

    create_master_csv(processed_folder_path)
    print("Processing completed. All ModuleGaze log files have been processed.")
