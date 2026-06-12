#!/usr/bin/env python3

import csv
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
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

DEFAULT_MODULEGAZE_API_BASE_URL = "http://127.0.0.1:3002"
DEFAULT_MODULE_MAP_FILE = os.path.join("config", "oc4d", "module-map.csv")
MODULE_ID_KEYS = ("moduleId", "moduleSlug", "module")
MODULE_NAME_KEYS = ("moduleName", "moduleTitle", "moduleDisplayName", "name", "title")
DYNAMIC_MODULE_SEGMENT = re.compile(r"^\d{10,}_[a-zA-Z0-9_-]+$")


def normalize_lookup_key(value):
    return value.strip().lower()


def add_module_alias(module_index, alias, module_name):
    alias = (alias or "").strip()
    module_name = (module_name or "").strip()
    if not alias or not module_name:
        return
    module_index[normalize_lookup_key(alias)] = module_name


def stable_module_slug_from_url(value):
    value = (value or "").strip()
    if not value:
        return ""
    try:
        parsed = urllib.parse.urlparse(value)
        path = parsed.path if parsed.scheme else value.split("#", 1)[0].split("?", 1)[0]
        path = urllib.parse.unquote(path)
    except Exception:
        path = value

    path_lower = path.lower()
    marker = "/uploads/modules/"
    if marker in path_lower:
        start = path_lower.index(marker) + len(marker)
        parts = [part for part in path[start:].split("/") if part]
        candidates = parts[:2]
    else:
        marker = "/modules/"
        if marker not in path_lower:
            return ""
        start = path_lower.index(marker) + len(marker)
        parts = [part for part in path[start:].split("/") if part]
        candidates = parts[:2]

    usable = []
    for candidate in candidates:
        if re.search(r"\.[a-z0-9]{1,10}$", candidate, re.IGNORECASE):
            break
        usable.append(candidate)
    stable = [part for part in usable if not DYNAMIC_MODULE_SEGMENT.match(part)]
    return stable[0] if stable else (usable[0] if usable else "")


def load_module_map_file(path):
    module_index = {}
    if not path or not os.path.isfile(path):
        return module_index

    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            return module_index
        for row in reader:
            source = (
                row.get("source_module_id")
                or row.get("moduleId")
                or row.get("module_id")
                or row.get("slug")
                or ""
            ).strip()
            if not source or source.startswith("#"):
                continue
            module_name = (
                row.get("moduleName")
                or row.get("module_name")
                or row.get("name")
                or row.get("Module Viewed")
                or ""
            ).strip()
            add_module_alias(module_index, source, module_name)
    return module_index


def fetch_module_catalog(api_base_url):
    api_base_url = (api_base_url or "").strip().rstrip("/")
    if not api_base_url or api_base_url.lower() in {"0", "false", "none", "off", "disabled"}:
        return []
    url = f"{api_base_url}/api/modules"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        print(f"ModuleGaze module catalog unavailable at {url}: {exc}")
        return []

    if isinstance(payload, dict):
        modules = payload.get("modules") or []
    elif isinstance(payload, list):
        modules = payload
    else:
        modules = []
    return modules if isinstance(modules, list) else []


def build_module_name_index():
    module_index = {}

    api_base_url = os.environ.get(
        "MODULEGAZE_API_BASE_URL",
        DEFAULT_MODULEGAZE_API_BASE_URL,
    )
    for module in fetch_module_catalog(api_base_url):
        if not isinstance(module, dict):
            continue
        module_name = str(module.get("name") or "").strip()
        if not module_name:
            continue
        add_module_alias(module_index, str(module.get("id") or ""), module_name)
        add_module_alias(module_index, module_name, module_name)
        add_module_alias(module_index, str(module.get("indexHtmlUrl") or ""), module_name)
        add_module_alias(
            module_index,
            stable_module_slug_from_url(str(module.get("indexHtmlUrl") or "")),
            module_name,
        )

    map_file = os.environ.get("MODULEGAZE_MODULE_MAP_FILE", DEFAULT_MODULE_MAP_FILE)
    module_index.update(load_module_map_file(map_file))
    return module_index


def parse_timestamp(value):
    value = value.lstrip("\ufeff").strip()
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


def resolve_module_viewed(fields, module_index):
    for key in MODULE_NAME_KEYS:
        value = (fields.get(key) or "").strip()
        if value:
            return module_index.get(normalize_lookup_key(value), value)

    for key in MODULE_ID_KEYS:
        value = (fields.get(key) or "").strip()
        if value:
            return module_index.get(normalize_lookup_key(value), value)

    return "none"


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


def parse_session_line(line, module_index):
    parts = line.lstrip("\ufeff").strip().split("\t")
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
        resolve_module_viewed(fields, module_index),
        fields.get("durationSeconds", ""),
    ]


def process_log_file(file_path, module_index):
    log_data = []
    skipped_count = 0
    source_log = os.path.basename(file_path)

    try:
        for line in iter_text_lines(file_path):
            try:
                row = parse_session_line(line, module_index)
                if row:
                    log_data.append(row)
                else:
                    skipped_count += 1
            except Exception as exc:
                skipped_count += 1
                if skipped_count <= 3:
                    print(f"Skipping line in {source_log}: {exc}")
    except (OSError, zipfile.BadZipFile) as exc:
        skipped_count += 1
        print(f"Skipping file {source_log}: {exc}")

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
    module_index = build_module_name_index()
    if module_index:
        print(f"Loaded {len(module_index)} ModuleGaze module aliases.")
    else:
        print("No ModuleGaze module aliases loaded; CSV will use raw moduleId values.")

    total_files = len(files_to_process)
    if total_files == 0:
        print(f"No ModuleGaze session log files found in {folder_path}.")

    for index, file_path in enumerate(sorted(files_to_process), start=1):
        log_data = process_log_file(file_path, module_index)
        save_processed_log_file(processed_folder_path, file_path, log_data)
        print(f"Processing files: {index}/{total_files}")

    create_master_csv(processed_folder_path)
    print("Processing completed. All ModuleGaze session log files have been processed.")
