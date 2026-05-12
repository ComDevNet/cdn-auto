# Upload

Manual upload tools and helpers.

Main pieces

- [upload.sh](./upload.sh) - pick a processed RACHEL run and send the final CSV to S3
- [modulegaze.sh](./modulegaze.sh) - pick a processed ModuleGaze run and send the final CSV to S3 under `ModuleGaze/`
- [kolibri.sh](./kolibri.sh) - export and upload Kolibri summary CSVs
- [process_csv.py](./process_csv.py) - filter summary.csv for a month and produce a final upload CSV
- [s3_bucket.sh](./s3_bucket.sh) - helper to pick/validate buckets

Usage

- Menu: [main.sh](./main.sh)
- Direct RACHEL upload: [upload.sh](./upload.sh)
- Direct ModuleGaze upload: [modulegaze.sh](./modulegaze.sh)

Inner workings

- upload.sh lists processed run folders under 00_DATA/00_PROCESSED and uploads to `RACHEL/`
- modulegaze.sh lists ModuleGaze processed folders and uploads to `ModuleGaze/`
- Both scripts make a working copy of summary.csv, filter it by month, and create deterministic filenames
- process_csv.py finds the Access Date column by header name, so it supports the normal RACHEL schemas and the ModuleGaze combined schema

Error modes

- Missing summary.csv: script exits and returns to menu
- Empty filtered dataset: process_csv.py prints nothing; no upload is attempted
- AWS CLI errors: surfaced to the terminal; verify credentials/region
