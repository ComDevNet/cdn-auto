# Upload

Manual upload tools and helpers.

## Main pieces

- [upload.sh](./upload.sh) — pick a processed RACHEL run and send the final CSV to S3
- [modulegaze.sh](./modulegaze.sh) — pick a processed ModuleGaze run and upload under `ModuleGaze/`
- [oc4d_assessments.sh](./oc4d_assessments.sh) — pull OC4D assessments (DB/API), stage, upload or queue
- [process_csv.py](./process_csv.py) — filter `summary.csv` for a month and produce a final upload CSV
- [s3_bucket.sh](./s3_bucket.sh) — helper to pick/validate buckets
- Flush Upload Queue (menu) — `FORCE_UPLOAD=1` via [../automation/flush_queue.sh](../automation/flush_queue.sh)

## Usage

- Menu: [main.sh](./main.sh)
- Direct RACHEL: [upload.sh](./upload.sh)
- Direct ModuleGaze: [modulegaze.sh](./modulegaze.sh)
- OC4D assessments: [oc4d_assessments.sh](./oc4d_assessments.sh)
- Flush queued uploads: [../automation/flush_queue.sh](../automation/flush_queue.sh)

## Inner workings

- `upload.sh` lists processed run folders under `00_DATA/00_PROCESSED` and uploads to `RACHEL/`
- `modulegaze.sh` lists ModuleGaze processed folders and uploads to `ModuleGaze/`
- Both make a working copy of `summary.csv`, filter by month, and create deterministic filenames
- `process_csv.py` finds the Access Date column by header name (RACHEL + ModuleGaze schemas)
- Queue flush walks `00_DATA/00_UPLOAD_QUEUE/{RACHEL,ModuleGaze,OC4DAssessments}/pending/` using `config/automation.conf`
- OC4D uses full S3 keys in `.oc4dkey` sidecars (key, optional `result_id`, optional scheme version)

## Error modes

- Missing `summary.csv`: script exits and returns to menu
- Empty filtered dataset: `process_csv.py` prints nothing; no upload is attempted
- AWS CLI errors: surfaced to the terminal; verify credentials/region
- OC4D mapping/validation failures: recorded in staging `manifest.json` `failed[]` without aborting other streams

Contracts: [docs/DEVELOPER-WIKI.md](../../../docs/DEVELOPER-WIKI.md).
