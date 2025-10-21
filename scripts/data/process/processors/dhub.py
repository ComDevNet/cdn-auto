import os
import csv
import json
import re
from datetime import datetime
from user_agents import parse
import sys

def process_log_file(file_path):
    """Process a single log file and extract data."""
    log_data = []

    # New regex: optional second "- " before the "[" 
    log_pattern = re.compile(
        r'(?P<ip>[\d.:]+)\s-\s(?:-\s)?\['
        r'(?P<timestamp>[^\]]+)\]\s"'
        r'(?P<request>GET|POST)\s'
        r'(?P<path>[^\s]+)\sHTTP/1\.1"\s'
        r'(?P<status_code>\d+|-)\s'
        r'(?P<size>\d+|-)\s'
        r'"(?P<referrer>[^"]*)"\s'
        r'"(?P<user_agent>[^"]*)"'
    )

    with open(file_path, 'r', encoding='utf-8') as log_file:
        for line in log_file:
            try:
                log_entry = json.loads(line)
                message = log_entry.get("message", "")

                match = log_pattern.search(message)
                if not match:
                    print(f"Skipping line (unexpected format): {message}")
                    continue

                g = match.groupdict()

                # Normalize IP
                ip = g["ip"]
                if ip.startswith("::ffff:"):
                    ip = ip[7:]

                # Parse timestamp (handles both ISO and space formats)
                ts = g["timestamp"]
                if ts.endswith("Z") and "T" in ts:
                    # e.g. 2024-12-17T23:59:40.761Z
                    timestamp = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ")
                else:
                    # e.g. 2025-01-28 12:34:56.789
                    timestamp = datetime.strptime(ts, "%Y-%m-%d %H:%M:%S.%f")
                access_date = timestamp.strftime("%Y-%m-%d")

                # Module name (for d-hub, extract from path like /uploads/modules/[id]/[module-name] or /uploads/other-modules/[module-name])
                path = g["path"]
                module = "none"
                
                # Try d-hub path pattern: /uploads/modules/[id]/[module-name] or /modules/[id]/[module-name] or /uploads/other-modules/[module-name]
                if "/uploads/modules/" in path:
                    parts = path.split("/uploads/modules/")[1].split("/")
                    if len(parts) >= 2:
                        module = parts[1]
                elif "/modules/" in path:
                    parts = path.split("/modules/")[1].split("/")
                    if len(parts) >= 2:
                        module = parts[1]
                elif "/uploads/other-modules/" in path:
                    parts = path.split("/uploads/other-modules/")[1].split("/")
                    if len(parts) >= 1:
                        module = parts[0]

                # User agent
                ua = parse(g["user_agent"])
                device = ua.os.family or "unknown"
                browser = ua.browser.family or "unknown"

                # Size → GB
                raw = g["size"]
                size_bytes = int(raw) if raw.isdigit() else 0
                size_gb = f"{size_bytes/1073741824:.10f}"

                log_data.append([
                    ip,
                    access_date,
                    module,
                    g["status_code"],
                    size_gb,
                    device,
                    browser,
                ])

            except Exception as e:
                print(f"Error processing line: {line.strip()}, Error: {e}")

    return log_data

def save_processed_log_file(folder_path, file_path, log_data):
    """Save the processed log data to a CSV file."""
    os.makedirs(folder_path, exist_ok=True)
    processed_file_path = os.path.join(
        folder_path,
        f"{os.path.splitext(os.path.basename(file_path))[0]}.csv"
    )
    
    if log_data:  # Only write files that have data
        with open(processed_file_path, 'w', encoding='utf-8', newline='') as output_file:
            csv_writer = csv.writer(output_file)
            csv_writer.writerow([
                'IP Address',
                'Access Date',
                'Module Viewed',
                'Status Code',
                'Data Saved (GB)',
                'Device Used',
                'Browser Used'
            ])
            csv_writer.writerows(log_data)


def create_master_csv(folder_path):
    """Create a master CSV file combining all processed CSV data."""
    master_csv_path = os.path.join(folder_path, "summary.csv")
    os.makedirs(folder_path, exist_ok=True)

    with open(master_csv_path, 'w', encoding='utf-8', newline='') as master_csv:
        csv_writer = csv.writer(master_csv)
        csv_writer.writerow([
            'IP Address',
            'Access Date',
            'Module Viewed',
            'Status Code',
            'Data Saved (GB)',
            'Device Used',
            'Browser Used'
        ])

        # Combine all individual CSVs into the master CSV
        for root, _, files in os.walk(folder_path):
            for file in files:
                if file.endswith(".csv") and file != "summary.csv":
                    file_path = os.path.join(root, file)
                    with open(file_path, 'r', encoding='utf-8') as csv_file:
                        csv_reader = csv.reader(csv_file)
                        next(csv_reader)  # Skip header
                        csv_writer.writerows(csv_reader)


if __name__ == '__main__':
    selected_folder = sys.argv[1]
    folder_path = os.path.join("00_DATA", selected_folder)
    processed_folder_path = os.path.join("00_DATA", "00_PROCESSED", selected_folder)

    if not os.path.exists(folder_path):
        print(f"Error: Folder '{folder_path}' does not exist.")
        sys.exit(1)

    total_files = sum(len(files) for _, _, files in os.walk(folder_path))
    processed_files = 0

    for root, _, files in os.walk(folder_path):
        for file in files:
            if file.endswith(".log"):
                file_path = os.path.join(root, file)
                log_data = process_log_file(file_path)
                save_processed_log_file(processed_folder_path, file_path, log_data)
                processed_files += 1
                print(
                    f"\rProcessing files: {processed_files}/{total_files} "
                    f"[{int((processed_files / total_files) * 100)}%]",
                    end='',
                    flush=True
                )

    # Create the master summary CSV
    create_master_csv(processed_folder_path)

    print("\nProcessing completed. All log files have been processed.")
