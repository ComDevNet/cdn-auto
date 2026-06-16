# Automation (Log Processor)

This module installs and runs the end-to-end data pipeline on a schedule: collect logs, process to CSV, time-window filter, upload to S3 (or queue if offline), export Kolibri summary snapshots to the `Kolibri/` S3 prefix, and collect/upload ModuleGaze session logs to the `ModuleGaze/` S3 prefix when `/var/log/modulegaze` exists.

Why systemd?

It provides reliable scheduling, dependency handling, robust logging via `journalctl`, and runs without an interactive session.

Key features

- Scheduled runs via systemd timer (daily, weekly, monthly, custom, and hourly for Castle logs)
- Offline-first uploads with queue flushing on the next successful run
- Stage-isolated execution so RACHEL, ModuleGaze, OC4D assessments, and Kolibri each get a chance to upload even if another stage has no logs or hits a processing error
- Shared S3 destination logic for `RACHEL/`, `Kolibri/`, `ModuleGaze/`, and OC4D assessment contract keys
- ModuleGaze session log export from active `.log` files and daily `.log.zip` archives, with module IDs resolved to display names
- Kolibri summary exports using the supported `kolibri manage exportlogs -l summary` CLI
- Built-in workaround for Kolibri `0.19.2`, which crashes if `start_date` and `end_date` are omitted
- Guided configuration with AWS bucket discovery and a live test upload
- Status dashboard covering timer, queue, connectivity, and AWS identity
- Dual logging to `journalctl` and `/var/log/v5_log_processor/automation.log`

Components

- `main.sh` - menu entrypoint for Install, Status, Configure
- `install.sh` - creates the service/timer and the wrapper at `/usr/local/bin/run_v5_log_processor.sh`
- `configure.sh` - writes `config/automation.conf`, discovers buckets/subfolders, validates with a live test upload, and sets the schedule
- `runner.sh` - orchestrates the pipeline, flushes queued uploads, and exports/upload Kolibri and ModuleGaze summaries
- `status.sh` - health/status report: timer/service, queue contents, connectivity, AWS identity, last logs
- `flush_queue.sh` - uploads queued CSVs for `RACHEL/`, `Kolibri/`, `ModuleGaze/`, and `OC4DAssessments/`
- `filter_time_based.py` - builds final CSVs for scheduled windows
- `scripts/data/lib/s3_helpers.sh` - shared bucket, upload, and queue helpers
- `scripts/data/lib/kolibri_helpers.sh` - shared Kolibri facility resolution and summary export helpers
- `scripts/data/lib/oc4d_assessment_helpers.sh` - OC4D assessment key builder, API fetch, and contract-key upload/queue helpers
- `scripts/data/process/processors/assessment.py` - fetches assessment results and emits validated CSV artifacts plus `manifest.json`

Configuration (`config/automation.conf`)

Written by `configure.sh` and kept inside the repo so the automation can run from the project directory.

- `SERVER_VERSION`: `v1` (Server v4/Apache), `v2` (Server v5/OC4D), `v3` (D-Hub), or `v6`
- `PYTHON_SCRIPT`: `oc4d` or `cape_coast_d` (only `v2`)
- `DEVICE_LOCATION`: short label used in folder names and output filenames
- `S3_BUCKET`: `s3://bucket-name`
- `S3_SUBFOLDER`: optional prefix under the bucket
- `RACHEL_SUBFOLDER`: optional subfolder under `.../RACHEL/` (for per-student server feeds)
- `KOLIBRI_FACILITY_ID`: optional override; if omitted, Kolibri's default facility is used
- `MODULEGAZE_ENABLED`: `1` to also process `/var/log/modulegaze`, `0` to skip it
- `MODULEGAZE_API_BASE_URL`: local ModuleGaze URL used to resolve module IDs to display names (default `http://127.0.0.1:3002`)
- `MODULEGAZE_MODULE_MAP_FILE`: optional CSV fallback for module ID to display-name mapping
- `OC4D_ASSESSMENTS_ENABLED`: `1` to pull assessment results from the local OC4D API and upload to the OC4D reports bucket
- `OC4D_API_BASE_URL`: local `oc4d-server` URL (default `http://127.0.0.1:3000`; not prompted during configure)
- `OC4D_API_TOKEN`: optional override; when empty, the runner auto-authenticates against the local API using the seeded super-admin account
- `OC4D_API_IDENTIFIER` / `OC4D_API_PASSWORD`: optional overrides if the local admin password was changed
- `OC4D_BUCKET`: destination bucket for assessment CSVs (default `oc4d-raw-reports`)
- `OC4D_PARENT_ORG`: parent org prefix used in S3 keys (for example `Home-Schooling`)
- `OC4D_UPLOAD_MODE`: `direct_s3` (default) or reserved `presigned_api`
- `OC4D_SOURCE_DIR`: optional folder of pre-exported assessment CSV files
- `OC4D_STUDENT_MAP_FILE`: optional CSV overrides from local student identity to cloud `studentId`
- `OC4D_STUDENT_PREFIX_SYNC`: `1` by default; resolves students from existing `OC4D_BUCKET/<parentOrg>/{Assessments,StudentReports,RACHEL,Kolibri}/<studentId>/` prefixes when email/username/name can infer the same ID
- `OC4D_CLOUD_STUDENTS_API_BASE_URL` / `OC4D_CLOUD_API_TOKEN`: optional cloud roster API source; when set, the processor calls `GET /students/{parentOrg}` and maps by `studentEmail`, `studentUsername`, display name, or `studentId`
- `OC4D_CLOUD_STUDENT_MAP_URL`, `OC4D_CLOUD_STUDENT_MAP_S3_URI`, `OC4D_CLOUD_STUDENT_MAP_FILE`: optional JSON/CSV roster sources using the same student fields
- `OC4D_ASSESSMENT_MAP_FILE`: optional CSV overrides for local assessment identity to cloud `assessmentId`; unmapped assessments are uploaded automatically using a generated slug from the assessment title
- `OC4D_STATE_FILE`: JSON state file tracking already-uploaded result IDs
- `SCHEDULE_TYPE`: `hourly` (Castle only), `daily`, `weekly`, `monthly`, `yearly`, or `custom`
- `RUN_INTERVAL`: for custom schedules (seconds, `>= 300`)

Data flow

1. Collect configured RACHEL logs

- `v1/v4`: copies `/var/log/apache2/access.log*` into `00_DATA/LOCATION_logs_YYYY_MM_DD`
- `v2/v5`: copies `/var/log/oc4d/oc4d-*.log`, Castle logs, and `.gz` files (excluding exceptions)
- `v3/dhub`: copies `/var/log/dhub/*.log`
- `v6`: copies `/var/log/oc4d/oc4d-*.log` (excluding exceptions)

2. Process and upload `RACHEL/`

- Chooses the matching processor and writes `00_DATA/00_PROCESSED/RUN_FOLDER/summary.csv`
- Filters the summary using the configured schedule window
- If online, queued files are flushed before the new CSV uploads
- If `RACHEL_SUBFOLDER` is set, uploads go to `.../RACHEL/<RACHEL_SUBFOLDER>/`
- If offline, the file is copied into `00_DATA/00_UPLOAD_QUEUE/RACHEL/`

3. Process and upload `ModuleGaze/`

- When enabled and `/var/log/modulegaze` exists, copies `modulegaze-sessions.log` and `modulegaze-sessions-*.log.zip` into `00_DATA/LOCATION_modulegaze_logs_YYYY_MM_DD`
- Processes session-duration rows into one `summary.csv`; `moduleId` values are resolved through `MODULEGAZE_API_BASE_URL/api/modules`, then `MODULEGAZE_MODULE_MAP_FILE` if present
- Filters the summary using the same schedule window
- Uploads to `S3_BUCKET/S3_SUBFOLDER/ModuleGaze/`, or queues in `00_DATA/00_UPLOAD_QUEUE/ModuleGaze/`

4. Pull and upload OC4D assessments

- When enabled on Server v5/v6, fetches `GET /api/assessment-results?scope=all` from the configured OC4D API
- Resolves cloud `studentId` from cloud roster sources plus `config/oc4d/student-map.csv` overrides, then existing S3 student prefixes; resolves `assessmentId` via `config/oc4d/assessment-map.csv` when present, otherwise generates a stable slug from the assessment title
- Builds validated CSV artifacts with header row plus one data row per result; if question metadata is missing, result answers are still exported under generic answer columns
- Uploads to `OC4D_BUCKET` using strict keys: `{parentOrg}/Assessments/{studentId}/{assessmentId}/{base}__{isoTs}.csv`
- If offline or upload fails, files are queued in `00_DATA/00_UPLOAD_QUEUE/OC4DAssessments/` with `.oc4dkey` sidecars

5. Export and upload `Kolibri/`

- Uses `kolibri manage exportlogs -l summary --start_date ... --end_date ...`
- Exports land in `00_DATA/00_KOLIBRI_EXPORTS/`
- If online, the summary CSV uploads to `S3_BUCKET/S3_SUBFOLDER/Kolibri/`
- If offline or the upload fails, the file is copied into `00_DATA/00_UPLOAD_QUEUE/Kolibri/`

Where things live

- Config: `config/automation.conf`
- Raw runs: `00_DATA/<DEVICE_LOCATION>_logs_YYYY_MM_DD/`
- ModuleGaze raw runs: `00_DATA/<DEVICE_LOCATION>_modulegaze_logs_YYYY_MM_DD/`
- Processed logs: `00_DATA/00_PROCESSED/<RUN_FOLDER>/`
- Kolibri exports: `00_DATA/00_KOLIBRI_EXPORTS/`
- OC4D assessment staging: `00_DATA/00_OC4D_ASSESSMENTS/`
- Upload queue: `00_DATA/00_UPLOAD_QUEUE/`
- Logs: `/var/log/v5_log_processor/automation.log` and `journalctl -u v5-log-processor.service`

Commands

- Install: `sudo ./scripts/data/automation/install.sh`
- Configure: `sudo ./scripts/data/automation/configure.sh`
- Status: `./scripts/data/automation/status.sh`
- Manual run (wrapper): `sudo /usr/local/bin/run_v5_log_processor.sh`
- Manual Kolibri export/upload: `./scripts/data/upload/kolibri.sh`
- Manual ModuleGaze upload: `./scripts/data/upload/modulegaze.sh`
- Manual OC4D assessment pull/upload: `./scripts/data/upload/oc4d_assessments.sh`

Troubleshooting

- Use `./scripts/data/automation/status.sh` to see timer state, queue contents, connectivity, AWS identity, and recent logs
- If uploads fail, the automation keeps the CSV in the matching queue folder for the next run
- If ModuleGaze CSVs still show raw IDs, confirm `curl -s http://127.0.0.1:3002/api/modules` returns module rows or add mappings to `config/oc4d/module-map.csv`
- If Kolibri export fails on `0.19.2`, confirm the command still receives both `--start_date` and `--end_date`
- If `KOLIBRI_FACILITY_ID` is not set, the scripts use Kolibri's default facility automatically
- If OC4D assessment uploads fall back to `unassigned`, confirm the student's cloud email/username/name matches the local OC4D result identity and that S3 student prefixes or a cloud roster source are available; `student-map.csv` is only an override
- OC4D queued uploads require both the CSV and its `.oc4dkey` sidecar in `OC4DAssessments/`
