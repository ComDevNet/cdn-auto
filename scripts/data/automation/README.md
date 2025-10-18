# Automation (Log Processor)

This module installs and runs the end‑to‑end data pipeline on a schedule: collect logs → process to CSV → time‑window filter → upload to S3 (or queue if offline).

Why systemd? It provides reliable scheduling (timer units), dependency handling, robust logging via journalctl, and runs without an interactive session.

Key features

- Scheduled runs via systemd timer (daily/weekly/monthly/custom; hourly for Castle logs)
- Offline‑first: queues uploads in 00_DATA/00_UPLOAD_QUEUE and flushes next time online
- Guided configuration with AWS bucket discovery and a live test upload
- Status dashboard covering timer, queue, connectivity, and AWS identity
- Dual logging to journalctl and /var/log/v5_log_processor/automation.log

Prerequisites

- Linux with systemd, bash, Python 3
- AWS CLI installed and configured for the service user (typically pi)
- Python dependencies for processors (see requirements.txt)

Components

- main.sh — Menu entrypoint for Install, Status, Configure
- install.sh — Creates service/timer and the wrapper at /usr/local/bin/run_v5_log_processor.sh
- configure.sh — Writes config/automation.conf; discovers buckets/subfolders; validates with live test upload; sets schedule
- runner.sh — Orchestrates the pipeline (collect → process → filter → upload/queue) and auto‑detects S3 bucket region
- status.sh — Health/status report: timer/service, queue contents, connectivity, AWS identity, last logs
- flush_queue.sh — Uploads any queued CSVs using per‑bucket region detection
- filter_time_based.py — Builds final CSVs for hourly/daily/weekly; automation calls process_csv.py for monthly
- /usr/local/bin/run_v5_log_processor.sh — Wrapper used by systemd to run runner.sh and tee output to both log and journal

Configuration (config/automation.conf)

Written by configure.sh and kept inside the repo so the automation can run from the project directory.

- SERVER_VERSION: v1 (Server v4/Apache) or v2 (Server v5/OC4D)
- PYTHON_SCRIPT: oc4d or cape_coast_d (only v2)
- DEVICE_LOCATION: short label used in folder names and output filenames
- S3_BUCKET: s3://bucket‑name
- S3_SUBFOLDER: optional prefix under the bucket; files go to subfolder/RACHEL/
- SCHEDULE_TYPE: hourly (castle only), daily, weekly, monthly, or custom
- RUN_INTERVAL: for custom schedules (seconds, >= 300)

Data flow

1. Collect

- v1/v4: copies /var/log/apache2 access.log\* into 00_DATA/LOCATION_logs_YYYY_MM_DD
- v2/v5: copies /var/log/oc4d oc4d-_.log, capecoastcastle-_.log, and \*.gz (excludes exceptions)
- Gzip files are decompressed

1. Process

- Chooses processor based on SERVER_VERSION and PYTHON_SCRIPT:
  - v1/v4 → scripts/data/process/processors/log.py
  - v2/v5 (oc4d) → scripts/data/process/processors/logv2.py
  - v2/v5 (cape_coast_d) → scripts/data/process/processors/castle.py
- Produces 00_DATA/00_PROCESSED/RUN_FOLDER/summary.csv

1. Filter to final CSV

- hourly/daily/weekly → filter_time_based.py selects the last completed window and writes a device‑named CSV in the same folder; it prints the filename to stdout
- monthly → scripts/data/upload/process_csv.py runs in filename mode to create LOCATION_MM_YYYY.csv and prints the filename

1. Upload or queue

- Connectivity check: if online, first flush queued files, then upload the new one using per‑bucket region detection; if offline, copy the new file to 00_DATA/00_UPLOAD_QUEUE

Scheduling

- Timer unit: v5-log-processor.timer
- Service unit: v5-log-processor.service
- Schedule is applied via override at /etc/systemd/system/v5-log-processor.timer.d/override.conf
- Modes:
  - hourly (only when PYTHON_SCRIPT=cape_coast_d)
  - daily, weekly, monthly
  - custom interval via OnUnitActiveSec=RUN_INTERVAL
- Timers are Persistent=true, so missed runs trigger shortly after boot

Where things live

- Config: config/automation.conf (chmod 600, owned by the service user)
- Raw runs: 00_DATA/<DEVICE_LOCATION>\_logs_YYYY_MM_DD/
- Processed: 00_DATA/00_PROCESSED/<DEVICE_LOCATION>\_logs_YYYY_MM_DD/
- Queue: 00_DATA/00_UPLOAD_QUEUE/
- Logs: /var/log/v5_log_processor/automation.log and journalctl -u v5-log-processor.service

Commands

- Install: sudo ./scripts/data/automation/install.sh
- Configure: sudo ./scripts/data/automation/configure.sh
- Status: ./scripts/data/automation/status.sh
- Manual run (wrapper): sudo /usr/local/bin/run_v5_log_processor.sh

Troubleshooting

- Use ./scripts/data/automation/status.sh to quickly see timer state, next/last run, queue, connectivity, and AWS identity
- If uploads fail, runner auto‑detects bucket region but credentials/policies can still block PUT; run Configure and use the live test or aws sts get-caller-identity
- “No new entries matched the time period” means summary.csv existed but didn’t contain rows in the last completed window
- If config can’t be read, ensure config/automation.conf exists and is readable; Configure will recreate it with correct ownership and perms
- To disable, sudo systemctl stop v5-log-processor.timer && sudo systemctl disable v5-log-processor.timer
