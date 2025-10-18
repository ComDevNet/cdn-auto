# Upload

Manual upload tools and helpers.

Main pieces

- upload.sh — pick a processed run and send the final CSV to S3
- process_csv.py — filter summary.csv for a month and produce LOCATION_MM_YYYY.csv (also used by automation in filename mode)
- s3_bucket.sh — helper to pick/validate buckets (if present)

Usage

- Menu: ./scripts/data/upload/main.sh
- Direct: ./scripts/data/upload/upload.sh

Inner workings

- upload.sh lists processed run folders (matching _log_) under 00_DATA/00_PROCESSED and prompts for selection
- It makes a working copy of summary.csv (summary_copy.csv) and invokes process_csv.py with:
  - folder path, device location (prompted), month (prompted, normalized to 2 digits), and input filename
  - in manual mode, process_csv.py prints the year; the final file is LOCATION_MM_YYYY.csv
- The script then prompts for an S3 subfolder and uploads to s3://rachel-upload-test/subfolder/RACHEL/LOCATION_MM_YYYY.csv

Error modes

- Missing summary.csv: script exits and returns to menu
- Empty filtered dataset: process_csv.py prints nothing; no upload is attempted
- AWS CLI errors: surfaced to the terminal; verify credentials/region
