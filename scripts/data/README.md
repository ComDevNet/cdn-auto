# Data Pipeline

Menus and scripts for collecting, processing, uploading, and automating analytics on CDN server logs.

Submodules

- collection — gathers logs from v4 (Apache) and v5 (OC4D)
- process — parses logs into CSV summaries via processors
- upload — manual month filtering and S3 upload
- automation — unattended runs with systemd

End‑to‑end flow

1. Collect: copies logs into 00_DATA/LOCATION_logs_YYYY_MM_DD and decompresses .gz
2. Process: writes 00_DATA/00_PROCESSED/RUN/summary.csv using the right processor
3. Finalize + Upload: either manual ([upload](./upload/)) or scheduled ([automation/runner.sh](./automation/runner.sh))

Data contracts

- Input logs (v4): text lines in Apache combined format (access.log\*)
- Input logs (v5): JSON per line with a message field that embeds HTTP request data
- Output CSV (summary.csv) columns (vary by processor) include at least:
  - IP Address, Access Date, Module Viewed, Status Code, Data Saved (GB), Device Used, Browser Used
  - Some processors (e.g., castle.py) also include Access Time and Location Viewed

Where to start

- Use [main.sh](./main.sh) to drive the whole flow, or jump into each submodule

See also: scripts/data/automation/README.md for unattended scheduling.
