# Automation (Log Processor)

This module installs and runs the end-to-end data pipeline on a schedule: collect logs, process to CSV, time-window filter, upload to S3 (or queue if offline), and export Kolibri summary snapshots to the `Kolibri/` S3 prefix.

Why systemd?

It provides reliable scheduling, dependency handling, robust logging via `journalctl`, and runs without an interactive session.

Key features

- Scheduled runs via systemd timer (daily, weekly, monthly, custom, and hourly for Castle logs)
- Offline-first uploads with queue flushing on the next successful run
- Shared S3 destination logic for both `RACHEL/` and `Kolibri/`
- Kolibri summary exports using the supported `kolibri manage exportlogs -l summary` CLI
- Built-in workaround for Kolibri `0.19.2`, which crashes if `start_date` and `end_date` are omitted
- Guided configuration with AWS bucket discovery and a live test upload
- Status dashboard covering timer, queue, connectivity, and AWS identity
- Dual logging to `journalctl` and `/var/log/v5_log_processor/automation.log`

Components

- `main.sh` — menu entrypoint for Install, Status, Configure
- `install.sh` — creates the service/timer and the wrapper at `/usr/local/bin/run_v5_log_processor.sh`
- `configure.sh` — writes `config/automation.conf`, discovers buckets/subfolders, validates with a live test upload, and sets the schedule
- `runner.sh` — orchestrates the pipeline, flushes queued uploads, and exports/upload Kolibri summaries
- `status.sh` — health/status report: timer/service, queue contents, connectivity, AWS identity, last logs
- `flush_queue.sh` — uploads any queued CSVs for both `RACHEL/` and `Kolibri/`
- `filter_time_based.py` — builds final CSVs for hourly/daily/weekly; automation calls `process_csv.py` for monthly
- `scripts/data/lib/s3_helpers.sh` — shared bucket, upload, and queue helpers
- `scripts/data/lib/kolibri_helpers.sh` — shared Kolibri facility resolution and summary export helpers

Configuration (`config/automation.conf`)

Written by `configure.sh` and kept inside the repo so the automation can run from the project directory.

- `SERVER_VERSION`: `v1` (Server v4/Apache), `v2` (Server v5/OC4D), `v3` (D-Hub), or `v6`
- `PYTHON_SCRIPT`: `oc4d` or `cape_coast_d` (only `v2`)
- `DEVICE_LOCATION`: short label used in folder names and output filenames
- `S3_BUCKET`: `s3://bucket-name`
- `S3_SUBFOLDER`: optional prefix under the bucket
- `KOLIBRI_FACILITY_ID`: optional override; if omitted, Kolibri's default facility is used
- `SCHEDULE_TYPE`: `hourly` (Castle only), `daily`, `weekly`, `monthly`, or `custom`
- `RUN_INTERVAL`: for custom schedules (seconds, `>= 300`)

Data flow

1. Collect

- `v1/v4`: copies `/var/log/apache2/access.log*` into `00_DATA/LOCATION_logs_YYYY_MM_DD`
- `v2/v5`: copies `/var/log/oc4d/oc4d-*.log`, Castle logs, and `.gz` files (excluding exceptions)
- `v3/dhub`: copies `/var/log/dhub/*.log`
- `v6`: copies `/var/log/oc4d/oc4d-*.log` (excluding exceptions)

2. Process

- Chooses the matching processor and writes `00_DATA/00_PROCESSED/RUN_FOLDER/summary.csv`

3. Filter + Upload `RACHEL/`

- Hourly, daily, and weekly runs use `filter_time_based.py`
- Monthly runs use `scripts/data/upload/process_csv.py`
- If online, queued `RACHEL/` files are flushed before the new CSV uploads
- If offline, the file is copied into `00_DATA/00_UPLOAD_QUEUE/RACHEL/`

4. Export + Upload `Kolibri/`

- Uses `kolibri manage exportlogs -l summary --start_date ... --end_date ...`
- Exports land in `00_DATA/00_KOLIBRI_EXPORTS/`
- If online, the summary CSV uploads to `S3_BUCKET/S3_SUBFOLDER/Kolibri/`
- If offline or the upload fails, the file is copied into `00_DATA/00_UPLOAD_QUEUE/Kolibri/`

Where things live

- Config: `config/automation.conf`
- Raw runs: `00_DATA/<DEVICE_LOCATION>_logs_YYYY_MM_DD/`
- Processed logs: `00_DATA/00_PROCESSED/<DEVICE_LOCATION>_logs_YYYY_MM_DD/`
- Kolibri exports: `00_DATA/00_KOLIBRI_EXPORTS/`
- Upload queue: `00_DATA/00_UPLOAD_QUEUE/`
- Logs: `/var/log/v5_log_processor/automation.log` and `journalctl -u v5-log-processor.service`

Commands

- Install: `sudo ./scripts/data/automation/install.sh`
- Configure: `sudo ./scripts/data/automation/configure.sh`
- Status: `./scripts/data/automation/status.sh`
- Manual run (wrapper): `sudo /usr/local/bin/run_v5_log_processor.sh`
- Manual Kolibri export/upload: `./scripts/data/upload/kolibri.sh`

Troubleshooting

- Use `./scripts/data/automation/status.sh` to see timer state, queue contents, connectivity, AWS identity, and recent logs
- If uploads fail, the automation still keeps the CSV in the matching queue folder for the next run
- If Kolibri export fails on `0.19.2`, confirm the command still receives both `--start_date` and `--end_date`
- If `KOLIBRI_FACILITY_ID` is not set, the scripts use Kolibri's default facility automatically
