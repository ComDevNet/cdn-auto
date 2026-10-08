# Data Pipeline

Menus and scripts for collecting, processing, uploading, and automating analytics on CDN server logs.

Canonical reference: [docs/DEVELOPER-WIKI.md](../../docs/DEVELOPER-WIKI.md).

## Submodules

- **collection** — gathers logs from v4 (Apache), v5 (OC4D), v3 (D-Hub), and v6 (OC4D with module paths)
- **process** — parses logs into CSV summaries via processors (includes `assessment.py`)
- **upload** — manual month filtering, ModuleGaze upload, OC4D assessments, queue flush
- **automation** — harvester + dispatcher systemd units
- **lib** — shared S3 / queue / OC4D helpers

## End-to-end flow

1. **Collect** — copies logs into `00_DATA/LOCATION_logs_YYYY_MM_DD` and decompresses `.gz`
2. **Process** — writes `00_DATA/00_PROCESSED/RUN/summary.csv` using the right processor
3. **Filter + enqueue** — automation filters by schedule window and writes `00_UPLOAD_QUEUE/{stage}/pending/`
4. **Dispatch / upload** — dispatcher (or manual flush) uploads when online and inside `UPLOAD_WINDOW`
5. **OC4D assessments** — DB-first harvest of results + marking schemes; maps student/assessment IDs; uploads to `OC4D_BUCKET`
   - Students resolve from cloud roster sources and existing cloud S3 student prefixes before local `student-map.csv` overrides; else `unassigned`
   - Unmapped assessments get generated stable IDs; assessment map is an override file
   - Result rows still export if question metadata is missing (generic answer columns)

## Data contracts

- Input logs (v4): Apache combined (`access.log*`)
- Input logs (v5): JSON per line with `message` embedding HTTP request data
- Input logs (v3): JSON per line; paths include UUID `/modules/[uuid]/[module-name]/`, `/uploads/modules/…`, or `/uploads/other-modules/…`
- Input logs (v6): JSON under `/var/log/oc4d`; module paths similar to v3
- OC4D assessment CSV: `{parentOrg}/Assessments/{studentId}/{assessmentId}/{base}__{isoTs}.csv`
- OC4D marking schemes: `{parentOrg}/MarkingSchemes/{assessmentId}/pi-sync-marking-scheme.csv` (+ `pi-sync-subject.json`)
- OC4D mapping templates: `config/oc4d/student-map.example.csv`, `assessment-map.example.csv` (live maps local/gitignored)
- Usage `summary.csv` columns (vary by processor) include at least:
  - IP Address, Access Date, Module Viewed, Status Code, Data Saved (GB), Device Used, Browser Used
  - Castle also includes Access Time and Location Viewed
  - `dhub.py` / `log-v6.py` share the `logv2.py` schema with extended module path extraction

## Queue layout

```text
00_DATA/00_UPLOAD_QUEUE/{RACHEL|ModuleGaze|OC4DAssessments}/{pending|uploading|completed|failed}/
```

See wiki §4 for sidecars (`.cdnrun`, `.oc4dkey`) and flush semantics.

## Where to start

- Menu: [main.sh](./main.sh)
- Automation: [automation/README.md](./automation/README.md)
