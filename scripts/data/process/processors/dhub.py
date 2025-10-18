#!/usr/bin/env python3
# This script is modeled on a working processor, as per Llewellyn's feedback.
import pandas as pd
import json
import re
import sys
import os
import glob
from typing import Dict, List, Optional

# A precise regex to capture only the relevant parts of a d-hub log message.
# Pattern looks for: /modules/{uuid}/{module-name}/
LOG_PATTERN = re.compile(
    r'"GET /(?:uploads/)?modules/(?P<module_id>[0-9a-fA-F-]+)/(?P<module_name>[a-zA-Z0-9_.-]+)/.*" '
    r'(?P<status_code>\d{3}) (?P<response_size>\d+|-)'
)

def parse_log_line(line: str) -> Optional[Dict]:
    """Parses a single JSON log line to extract d-hub access info."""
    try:
        log_entry = json.loads(line)
        message = log_entry.get("message", "")
        # Extract the IP from the start of the message
        ip_address = message.split(' ', 1)[0]
    except (json.JSONDecodeError, AttributeError, IndexError):
        return None

    match = LOG_PATTERN.search(message)
    if not match:
        return None

    data = match.groupdict()
    data['ip_address'] = ip_address
    data['response_size'] = 0 if data['response_size'] == '-' else int(data['response_size'])
    data['status_code'] = int(data['status_code'])
    # Use the more accurate timestamp from the JSON body
    data['timestamp'] = log_entry.get("timestamp")

    return data

def main(folder_name: str):
    """Processes all log files in a given folder and creates a summary.csv."""
    script_path = os.path.dirname(os.path.realpath(__file__))
    project_root = os.path.abspath(os.path.join(script_path, "../../../.."))

    input_dir = os.path.join(project_root, "00_DATA", folder_name)
    output_dir = os.path.join(project_root, "00_DATA", "00_PROCESSED", folder_name)

    if not os.path.isdir(input_dir):
        print(f"Error: Input directory not found at {input_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)
    output_csv_path = os.path.join(output_dir, "summary.csv")

    all_logs = []
    log_files = glob.glob(os.path.join(input_dir, '*'))
    print(f"Found {len(log_files)} files in {input_dir} to process.")

    for file_path in log_files:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                parsed_data = parse_log_line(line)
                if parsed_data:
                    all_logs.append(parsed_data)

    if not all_logs:
        print("No valid d-hub log entries were found.")
        pd.DataFrame(columns=['ip_address', 'timestamp', 'module_id', 'module_name', 'status_code', 'response_size']).to_csv(output_csv_path, index=False)
        return

    df = pd.DataFrame(all_logs)
    column_order = ['ip_address', 'timestamp', 'module_id', 'module_name', 'status_code', 'response_size']
    df = df[column_order] 
    df.to_csv(output_csv_path, index=False)

    print(f"✅ Processing complete. {len(df)} entries saved to {output_csv_path}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 dhub.py <folder_name>", file=sys.stderr)
        sys.exit(1)

    target_folder = sys.argv[1]
    main(target_folder)
