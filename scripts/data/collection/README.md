# Collection

Collect server logs from:

- v4 (Apache) at /var/log/apache2 (access.log\*)
- v5 (OC4D) at /var/log/oc4d (oc4d-_.log, capecoastcastle-_.log, *.gz; excludes *exceptions\*)
- v3 (D-Hub) at /var/log/dhub (\*.log)

Outputs

- Creates a run folder in 00_DATA named LOCATION_logs_YYYY_MM_DD and copies relevant files there
- Decompresses any .gz files in-place
- Skips exception logs (e.g., oc4d-exceptions-\*.log) to avoid noise

Usage

- Run the menu: [scripts/data/collection/main.sh](../../data/collection/main.sh)
- To collect directly: [scripts/data/collection/all.sh](../../data/collection/all.sh)

Inner workings

- The script prompts for server type (v4, v5, or v3) and device location (used in the folder name)
- v4 copies files matching access.log\* from /var/log/apache2
- v5 copies:
  - oc4d-_.log (excluding oc4d-exceptions-_.log)
  - capecoastcastle-_.log (excluding capecoastcastle-exceptions-_.log)
  - any \*.gz files
- v3 copies \*.log files from /var/log/dhub
- After copying, .gz files are decompressed so processors can read plain text
- The resulting folder is moved into 00_DATA for the processing stage
