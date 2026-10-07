# Automation (Harvester + Dispatcher)

CDN-auto **harvests whenever the device is on** into a durable local queue, and **uploads only during a configured upload window** (or when you force-flush).

Near-realtime: choose **Near-realtime every 15/30/60 min** in Configure. That sets `SCHEDULE_TYPE=near_realtime` (today→now rolling window, stamped every interval), `HARVEST_INTERVAL`/`RUN_INTERVAL` to match, and `UPLOAD_WINDOW=always` so dispatch runs on the same cadence.

Streams: RACHEL usage, ModuleGaze, OC4D assessments. **Kolibri is out** (not produced by cdn-auto).

Canonical contracts: [docs/DEVELOPER-WIKI.md](../../../docs/DEVELOPER-WIKI.md).

## Key features

- Separate harvester + dispatcher systemd timers (power-cycle safe)
- Harvest works offline: collect → process → filter → enqueue only
- Durable queue under `00_DATA/00_UPLOAD_QUEUE/{stage}/{pending,uploading,completed,failed}/`
- Configurable `UPLOAD_WINDOW` (`always` or `HH:MM-HH:MM`)
- Near-realtime rolling windows for non-Castle sites (15–60 min)
- Flock lock so harvest/dispatch do not overlap (wait up to 900s, then skip)
- Dedup by payload basename / OC4D result id / marking-scheme version
- Crash recovery: `uploading/` → `pending/` on prepare
- Stage-isolated RACHEL / ModuleGaze / OC4DAssessments

## Data flow

1. **Harvest** (`runner.sh harvest`): RACHEL → ModuleGaze (optional) → OC4D assessments (optional) → enqueue `pending/`
2. **Dispatch** (`runner.sh dispatch`): if window open and online → `flush_all_queues` → S3 → `completed/`
3. Markers: `.last_harvest_ok`, `.last_upload_ok` under the queue root
4. Lock file (install wrappers): `/home/pi/cdn-auto/00_DATA/00_UPLOAD_QUEUE/.automation.lock`

## Config highlights

- `SCHEDULE_TYPE`: `near_realtime` | `daily` | `weekly` | `monthly` | `yearly` | `custom` | Castle-only `hourly`
- `RUN_INTERVAL` / `HARVEST_INTERVAL`: seconds (near-realtime presets: 900 / 1800 / 3600)
- `UPLOAD_WINDOW`: `always` or `HH:MM-HH:MM` (near-realtime forces `always`; daily default `00:00-01:00`)
- OC4D: see [config/README.md](../../../config/README.md) — assessments are **DB-first** with API fallback; students/assessments auto-map when possible

## Commands

```bash
sudo ./scripts/data/automation/install.sh
sudo ./scripts/data/automation/configure.sh
./scripts/data/automation/status.sh
./scripts/data/automation/flush_queue.sh          # FORCE_UPLOAD=1
sudo /usr/local/bin/run_v5_log_harvester.sh
sudo /usr/local/bin/run_v5_log_dispatcher.sh
```

Legacy combined wrapper (still installed): `/usr/local/bin/run_v5_log_processor.sh` → `runner.sh all`.

## Pi validation (near-realtime)

One-shot after `git pull` (existing `config/automation.conf`):

```bash
sudo ./scripts/data/automation/migrate_near_realtime.sh
./scripts/data/automation/status.sh
```

Or: Install + Configure → Near-realtime 15/30/60 min.

Then generate local activity. Within ~15–30 min (with uplink), **RACHEL** CSVs under `oc4d-raw-reports/…/RACHEL/` should refresh the OC4D **usage** dashboard (S3 → `csv-report-generator-triggered` → `oc4d-reports-table`). Assessment / ModuleGaze objects upload to S3 on the same cadence but are **not** ingested by that Lambda today — see [docs/DEVELOPER-WIKI.md §14](../../../docs/DEVELOPER-WIKI.md#14-cloud-ingest-verified-against-oc4d). Offline: pending accumulates; reconnect + dispatcher flush without manual steps.

Local smoke: `./scripts/data/automation/validate_near_realtime.sh`

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Nothing uploading | `UPLOAD_WINDOW`, connectivity, `status.sh` pending counts |
| Overlapping skips | Lock held — wait or inspect running units |
| OC4D `[oc4d] Disabled` | `OC4D_ASSESSMENTS_ENABLED=1` via configure |
| Assessments empty | Local DB / `oc4d_db` container; mappings; `uploaded-state.json` |
| Wrong bucket | RACHEL uses `S3_BUCKET`; assessments use `OC4D_BUCKET` |
