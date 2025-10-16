# scripts/data/process/processors/dhub.py

import os
import re
import json
import csv
import sys
from datetime import datetime

# This regex is the key change. It's designed to capture the new d-hub URL format.
# It looks for lines containing /modules/ followed by a UUID.
LOG_PATTERN = re.compile(
    r'(\S+) - - \[([^\]]+)\] "(\S+) /modules/([0-9a-fA-F\-]+)/([^/]+)/?(\S*) HTTP/\d\.\d" (\d+) (\d+) "([^"]*)" "([^"]*)"'
)

# A simpler pattern for other module requests that might not have a UUID
FALLBACK_PATTERN = re.compile(
    r'(\S+) - - \[([^\]]+)\] "(\S+) /modules/([^/]+)/?(\S*) HTTP/\d\.\d" (\d+) (\d+) "([^"]*)" "([^"]*)"'
)

def parse_log_file(file_path, writer):
    """Parses a single log file and writes valid entries to the CSV writer."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            for line in f:
                try:
                    # The log lines are JSON objects
                    log_entry = json.loads(line)
                    message = log_entry.get("message", "")

                    # We only care about the lines that contain actual request data
                    if "GET /modules/" not in message and "GET /_next/" not in message:
                        continue

                    # First, try to match the detailed d-hub pattern with a UUID
                    match = LOG_PATTERN.search(message)
                    if match:
                        (ip, timestamp, method, module_id, module_name, rest_of_path, status, size, referrer, user_agent) = match.groups()
                        module_viewed = module_name
                    else:
                        # If it doesn't match, try the fallback for simpler module URLs
                        fallback_match = FALLBACK_PATTERN.search(message)
                        if fallback_match:
                            (ip, timestamp, method, module_name, rest_of_path, status, size, referrer, user_agent) = fallback_match.groups()
                            module_viewed = module_name
                        else:
                            # If neither pattern matches, skip this line
                            continue

                    # Format the timestamp
                    dt_obj = datetime.strptime(timestamp, "%d/%b/%Y:%H:%M:%S %z")
                    access_date = dt_obj.strftime("%Y-%m-%d")
                    access_time = dt_obj.strftime("%H:%M:%S")

                    # Write the parsed data to the CSV
                    writer.writerow([
                        ip, access_date, access_time, module_viewed,
                        'd-hub', status, size, 'Unknown', user_agent
                    ])
                except (json.JSONDecodeError, ValueError, TypeError):
                    # This will skip malformed lines
                    continue
    except Exception as e:
        print(f"Error processing file {file_path}: {e}")


def main(folder_name):
    """Main function to process all log files in a given directory."""
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../'))
    collected_dir = os.path.join(project_root, '00_DATA', folder_name)
    processed_dir = os.path.join(project_root, '00_DATA', '00_PROCESSED', folder_name)

    if not os.path.exists(collected_dir):
        print(f"Error: Collected data directory not found at {collected_dir}")
        return

    os.makedirs(processed_dir, exist_ok=True)

    output_csv_path = os.path.join(processed_dir, 'summary.csv')

    with open(output_csv_path, 'w', newline='', encoding='utf-8') as csvfile:
        writer = csv.writer(csvfile)
        # Write header
        writer.writerow([
            "IP Address", "Access Date", "Access Time", "Module Viewed",
            "Location Viewed", "Status Code", "Data Saved (GB)",
            "Device Used", "Browser Used"
        ])

        print(f"Processing log files in {collected_dir}...")
        # Find all log files (not ending in .gz)
        for filename in os.listdir(collected_dir):
            if filename.endswith(".log"):
                file_path = os.path.join(collected_dir, filename)
                print(f"  - Parsing {filename}...")
                parse_log_file(file_path, writer)

        print(f"Processing complete. Summary saved to {output_csv_path}")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: python3 dhub.py <folder_name>")
        sys.exit(1)
    main(sys.argv[1])
