import os
import csv
import json
import re
import sys
from urllib.parse import unquote
from user_agents import parse
from datetime import datetime
from typing import Iterator

# --- Constants ---
LOG_MESSAGE_PATTERN = re.compile(
    r'^(\S+)\s-'                # 1. IP Address
    r'\s\[(.*?)\]\s'            # 2. Timestamp
    r'"(.*?)"\s'                # 3. Request
    r'(\d{3})\s'                # 4. Status Code
    r'(\S+)\s'                  # 5. Response Size
    r'"(.*?)"\s'                # 6. Referrer (unused)
    r'"(.*?)"$'                 # 7. User Agent
)

REQUEST_PATH_PATTERN = re.compile(r'^[A-Z]+\s+(.*?)\s+HTTP/\d\.\d$')
MODULES_PATTERN = re.compile(r'/modules/([^/]+)/')
MODULES_LOCATION_PATTERN = re.compile(r'/modules/[^/]+/([^/]+)\.\w+$')
INTERACTIVE_MAP_PATTERN = re.compile(r'/interactive-map/(\d+-[^/]+)')

GIGABYTE = 1024 ** 3


def process_log_file(file_path: str, error_log_path: str = None) -> Iterator[list]:
    """
    Processes a log file line-by-line and yields structured data rows.
    Invalid lines can optionally be written to an error log.
    """
    error_log = open(error_log_path, 'a', encoding='utf-8') if error_log_path else None

    with open(file_path, 'r', encoding='utf-8') as log_file:
        for line_number, line in enumerate(log_file, start=1):
            line = line.strip()
            if not line:
                continue

            try:
                log_entry = json.loads(line)
                message = log_entry.get("message", "")
            except json.JSONDecodeError:
                if error_log:
                    error_log.write(f"[JSON Error] Line {line_number}: {line}\n")
                continue

            match = LOG_MESSAGE_PATTERN.match(message)
            if not match:
                if error_log:
                    error_log.write(f"[Regex Mismatch] Line {line_number}: {line}\n")
                continue

            ip_address, timestamp_str, request, status_code, size_bytes, _, ua_string = match.groups()

            if ip_address.startswith("::ffff:"):
                ip_address = ip_address[7:]

            try:
                timestamp = datetime.strptime(timestamp_str, "%Y-%m-%dT%H:%M:%S.%fZ")
            except ValueError:
                if error_log:
                    error_log.write(f"[Timestamp Error] Line {line_number}: {timestamp_str}\n")
                continue

            path_match = REQUEST_PATH_PATTERN.match(request)
            path = path_match.group(1) if path_match else ''
            cleaned_path = unquote(path)

            module_name = 'none'
            location_viewed = 'none'

            if (modules_match := MODULES_PATTERN.search(cleaned_path)):
                module_name = modules_match.group(1)
                if (location_match := MODULES_LOCATION_PATTERN.search(cleaned_path)):
                    location_viewed = location_match.group(1)
                    if location_viewed.lower() == 'index':
                        location_viewed = 'Home Page'
            elif (interactive_match := INTERACTIVE_MAP_PATTERN.search(cleaned_path)):
                module_name = 'interactive-map'
                location_viewed = interactive_match.group(1)

            if location_viewed.lower() == 'card':
                location_viewed = 'none'

            user_agent = parse(ua_string or "")
            os_family = user_agent.os.family or 'Unknown'
            browser_name = user_agent.browser.family or 'Unknown'

            response_size_gb = (int(size_bytes) / GIGABYTE) if size_bytes.isdigit() else 0.0

            yield [
                ip_address,
                timestamp.strftime("%Y-%m-%d"),
                timestamp.strftime("%H:%M:%S"),
                module_name,
                location_viewed,
                status_code,
                f"{response_size_gb:.5f}",
                os_family.lower(),
                browser_name
            ]

    if error_log:
        error_log.close()


def main():
    """
    Main function to process log files from a specified folder.
    """
    if len(sys.argv) < 2:
        print("Error: Please provide the source folder name as an argument.")
        print(f"Usage: python {sys.argv[0]} <folder_name>")
        sys.exit(1)

    selected_folder = sys.argv[1]
    source_folder = os.path.join("00_DATA", selected_folder)
    processed_folder = os.path.join("00_DATA", "00_PROCESSED", selected_folder)
    error_log_path = os.path.join(processed_folder, "error_log.txt")

    if not os.path.exists(source_folder):
        print(f"Error: Source folder '{source_folder}' not found.")
        sys.exit(1)

    os.makedirs(processed_folder, exist_ok=True)

    log_files = [
        os.path.join(root, file)
        for root, _, files in os.walk(source_folder)
        for file in files if file.endswith(".log")
    ]

    total_files = len(log_files)
    if total_files == 0:
        print("No .log files found to process.")
        return

    print(f"Found {total_files} log file(s). Starting processing...")

    master_summary_path = os.path.join(processed_folder, "summary.csv")
    csv_header = [
        'IP Address', 'Access Date', 'Access Time', 'Module Viewed',
        'Location Viewed', 'Status Code', 'Data Saved (GB)',
        'Device Used', 'Browser Used'
    ]

    total_rows_written = 0

    with open(master_summary_path, 'w', encoding='utf-8', newline='') as master_file:
        master_writer = csv.writer(master_file)
        master_writer.writerow(csv_header)

        processed_files = 0
        for file_path in log_files:
            base_filename = os.path.splitext(os.path.basename(file_path))[0]
            output_path = os.path.join(processed_folder, f"{base_filename}.csv")

            with open(output_path, 'w', encoding='utf-8', newline='') as individual_file:
                individual_writer = csv.writer(individual_file)
                individual_writer.writerow(csv_header)

                row_count = 0
                for row in process_log_file(file_path, error_log_path=error_log_path):
                    individual_writer.writerow(row)
                    master_writer.writerow(row)
                    row_count += 1
                total_rows_written += row_count

            processed_files += 1
            progress = int((processed_files / total_files) * 100)
            bar_length = 50
            filled_length = int(bar_length * progress // 100)
            bar = '=' * filled_length + '-' * (bar_length - filled_length)
            print(f"\rProcessing: {progress}% |{bar}|", end='')

    print("\n\nProcessing completed successfully.")
    print(f"Processed {total_files} files, {total_rows_written} total rows.")
    print(f"All processed data saved in: {processed_folder}")
    print(f"Master summary created at: {master_summary_path}")
    print(f"Errors (if any) logged to: {error_log_path}")


if __name__ == '__main__':
    main()