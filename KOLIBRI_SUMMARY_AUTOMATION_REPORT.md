# Kolibri Summary Automation Report

Date: 2026-04-06
Target device: `pi@192.168.8.171`
Repo: `/home/pi/cdn-auto`

## What was requested

Add Kolibri summary CSV pulling to both the scheduled `cdn-auto` automation flow and the manual data/upload flow, then place those files in the same S3 bucket/subfolder structure already used by the automation, but under `Kolibri/` instead of `RACHEL/`.

## What I found before changing anything

- The live automation repo is `/home/pi/cdn-auto`.
- The current automation uploader hardcoded `RACHEL/` in both:
  - `scripts/data/automation/runner.sh`
  - `scripts/data/automation/flush_queue.sh`
- The current manual upload flow only handled processed server logs:
  - `scripts/data/upload/main.sh`
  - `scripts/data/upload/upload.sh`
- The device is running Kolibri `0.19.2`.
- The live Kolibri default facility on this device is:
  - `eb08d9119e45d96357cd2d353b62b213`
  - `Home Facility for Community Development Network`
- The installed Kolibri command supports the export we need:
  - `kolibri manage exportlogs -l summary`
- The installed Kolibri version has a real CLI bug:
  - `kolibri manage exportlogs -l summary -O file.csv -w` crashes when `--start_date` and `--end_date` are omitted.
  - Verified workaround: always pass an explicit date range, for example:
    - `--start_date 1970-01-01T00:00:00`
    - `--end_date <current timestamp>`
- The live bucket structure in `s3://oc4d-raw-reports/` follows:
  - `<Site>/<Folder>/...`
  - Example: `Cape-Coast-Castle/RACHEL/...`

## What was implemented

### 1. Shared S3 helper layer

Added shared helpers in:

- `scripts/data/lib/s3_helpers.sh`

This centralizes:

- bucket region detection
- `S3_BUCKET + S3_SUBFOLDER` path building
- uploads to a chosen destination folder (`RACHEL` or `Kolibri`)
- queue directory creation
- queue flushing for both destinations
- backward-compatible flushing of any old queue files still sitting at the queue root

### 2. Shared Kolibri export helper layer

Added:

- `scripts/data/lib/kolibri_helpers.sh`

This handles:

- checking whether Kolibri is installed
- resolving the default Kolibri facility if `KOLIBRI_FACILITY_ID` is not set
- building a timestamped export filename
- exporting the summary CSV with the mandatory `start_date` / `end_date` workaround

### 3. Automation runner

Updated:

- `scripts/data/automation/runner.sh`

Changes:

- still runs the existing collect/process/filter/upload flow for `RACHEL/`
- no longer exits early when there is no new processed OC4D data
- now flushes queued `RACHEL/` and `Kolibri/` files when internet is available
- now exports a Kolibri summary snapshot on every automation run when Kolibri is installed
- uploads the exported summary to:
  - `S3_BUCKET/S3_SUBFOLDER/Kolibri/<timestamped-file>.csv`
- queues the Kolibri export if upload fails or the device is offline
- keeps the automation compatible with devices that do not have Kolibri installed by logging and skipping cleanly

### 4. Queue flusher

Updated:

- `scripts/data/automation/flush_queue.sh`

It now flushes:

- legacy root queue files as `RACHEL/`
- `00_DATA/00_UPLOAD_QUEUE/RACHEL/*.csv`
- `00_DATA/00_UPLOAD_QUEUE/Kolibri/*.csv`

### 5. Manual flow

Updated:

- `scripts/data/upload/main.sh`

Added a new manual entrypoint:

- `scripts/data/upload/kolibri.sh`

Manual behavior now:

- loads the current automation bucket/subfolder config if available
- lets the operator confirm or override that destination
- exports the Kolibri summary CSV
- uploads it to the matching `Kolibri/` S3 folder
- if the upload fails, queues it for the next automation flush

### 6. Documentation

Updated:

- `scripts/data/README.md`
- `scripts/data/automation/README.md`

Added this report:

- `KOLIBRI_SUMMARY_AUTOMATION_REPORT.md`

## How the new flow works

### Automation

1. Existing server logs are collected and processed as before.
2. If a `RACHEL` CSV is produced for the configured schedule window, it uploads or queues.
3. Kolibri summary export runs separately from that result.
4. The Kolibri export is saved locally in:
   - `00_DATA/00_KOLIBRI_EXPORTS/`
5. If online, it uploads to:
   - `S3_BUCKET/S3_SUBFOLDER/Kolibri/`
6. If offline or S3 upload fails, it is copied into:
   - `00_DATA/00_UPLOAD_QUEUE/Kolibri/`
7. A later run or `flush_queue.sh` uploads the queued file.

### Manual

1. Open the Upload menu.
2. Choose `Upload Kolibri Summary`.
3. Confirm the configured destination or enter another one.
4. The script exports the Kolibri summary CSV.
5. It uploads to the same bucket/subfolder path used by automation, but under `Kolibri/`.
6. If upload fails, the file is queued automatically.

## Error handling added

- Kolibri not installed:
  - automation logs a skip instead of failing the whole run
- Kolibri CLI bug on `0.19.2`:
  - the scripts always pass `--start_date` and `--end_date`
- no internet:
  - new files are queued
- upload failure:
  - files stay queued for later retry
- old queued files from the pre-Kolibri layout:
  - still flush correctly as `RACHEL/`

## Validation performed

Verified on `192.168.8.171`:

- Kolibri version: `0.19.2`
- `kolibri manage help exportlogs` supports `summary`, `--facility`, `--start_date`, `--end_date`, `-O`, and `-w`
- `exportlogs` fails without dates on this version
- `exportlogs` succeeds when both dates are supplied
- live S3 bucket layout in `s3://oc4d-raw-reports/` matches the expected `<Site>/<Folder>/...` structure

## Assumptions

- Devices with Kolibri normally use the default Kolibri facility unless `KOLIBRI_FACILITY_ID` is set manually in `config/automation.conf`
- The requested `Kolibri` destination folder should use this exact casing:
  - `Kolibri`
- Kolibri summary exports should preserve the full summary snapshot behavior rather than trying to reduce it to the OC4D log-processing schedule window
