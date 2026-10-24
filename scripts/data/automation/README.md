# Automation (Harvester + Dispatcher)

CDN-auto **harvests whenever the device is on** into a durable local queue, and **uploads only during a configured upload window** (or when you force-flush).

Near-realtime: choose **Near-realtime every 15/30/60 min** in Configure. That sets `SCHEDULE_TYPE=near_realtime` (today→now rolling window, stamped every interval), `HARVEST_INTERVAL`/`RUN_INTERVAL` to match, and `UPLOAD_WINDOW=always` while dispatch retries independently every minute after each attempt.

Streams: RACHEL usage, ModuleGaze, OC4D assessments. **Kolibri is out** (not produced by cdn-auto).

Canonical contracts: [docs/DEVELOPER-WIKI.md](../../../docs/DEVELOPER-WIKI.md).

## Key features

- Separate harvester + dispatcher systemd timers (power-cycle safe)
- Harvest and dispatch run with low CPU weight and idle disk priority so the web server takes precedence
- Harvest works offline: collect → process → filter → enqueue only
- Durable queue under `00_DATA/00_UPLOAD_QUEUE/{stage}/{pending,uploading,completed,failed}/`
- Configurable `UPLOAD_WINDOW` (`always` or `HH:MM-HH:MM`)
- Near-realtime rolling windows for non-Castle sites (15–60 min)
- Flock lock so harvest/dispatch do not overlap (wait up to 900s, then skip)
- Dedup by payload basename / OC4D result id / marking-scheme version
- Crash recovery: `uploading/` → `pending/` on prepare
- Stage-isolated RACHEL / ModuleGaze / OC4DAssessments

## Data flow

1. **Harvest** (`runner.sh harvest`): collect logs, process them, filter the schedule window, and enqueue CSVs. RACHEL summaries combine only CSVs generated from source logs in this processing pass. Previous filtered exports and stale intermediate CSVs are excluded, preventing repeated harvests from duplicating earlier output.
2. **Enqueue**: compare the CSV byte-for-byte with its queue copy before removing the processed working folder. Failed or incomplete copies preserve the working folder. Pending uploads remain queued while offline.
3. **Dispatch** (`runner.sh dispatch`): when the upload window is open and connectivity is available, upload pending files to S3 and move successful uploads to `completed/`. AWS progress output is disabled so failed multipart transfers do not flood the automation log.
4. Markers: `.last_harvest_ok`, `.last_upload_ok` under the queue root.
5. Lock file (installed wrappers): `/home/pi/cdn-auto/00_DATA/00_UPLOAD_QUEUE/.automation.lock`.

The installer adds daily rotation for `/var/log/v5_log_processor/automation.log`, with a 25 MB size threshold and four compressed rotations. The system logrotate schedule must be enabled. V5/V6 processors report ignored and malformed line counts per file instead of printing every line. Pending uploads are never removed to enforce a disk quota; sustained upload failures still need attention.

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
./scripts/data/automation/backfill_s3_days.sh     # dry-run: local log days vs S3 gaps
./scripts/data/automation/backfill_s3_days.sh --apply --flush
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
| Disk nearly full / multi‑GiB `*_access_logs.csv` in queue | Pre-fix NR re-import blowup — run `repair_storage_blowup.sh` (dry-run, then `--apply`), then update + `install.sh` |
| Past days missing in S3 after NR / blowup repair | Near-realtime only exports today→now — run **Backfill Missing S3 Days** (menu) or `backfill_s3_days.sh --apply --flush` |
| OC4D `[oc4d] Disabled` | `OC4D_ASSESSMENTS_ENABLED=1` via configure |
| Assessments empty | Local DB / `oc4d_db` container; mappings; `uploaded-state.json` |
| Wrong bucket | RACHEL uses `S3_BUCKET`; assessments use `OC4D_BUCKET` |

### Repair already-full devices

**From the CDN Auto menu (preferred):**

1. **Troubleshoot → Storage → Repair storage blowup**, or **Data → Automation → Repair Storage Blowup**
2. Review the dry-run, then confirm apply (optional: purge all NR exports, vacuum journal)
3. **Update** the Pi, then **Data → Automation → Install** so the fixed processors + logrotate are live

**Install does not auto-delete queue files.** It only truncates a huge `automation.log`, installs logrotate, and if blowup symptoms are detected will *ask* whether to open the same interactive repair before starting timers.

CLI (same script the menu runs):

```sh
./scripts/data/automation/repair_storage_blowup.sh            # dry-run
sudo ./scripts/data/automation/repair_storage_blowup.sh --apply --purge-all-nr-exports --vacuum-journal
```

Removes orphan `.*.tmp.*` enqueue files, RACHEL/ModuleGaze queue CSVs over 100 MiB (corrupt re-import products), optional `--purge-all-nr-exports` for every near-realtime queue CSV of any size, bloated `00_PROCESSED` run folders, and truncates a huge `automation.log`. Source `/var/log/oc4d` (etc.) is kept so harvest can rebuild correct CSVs.

### Backfill missing S3 days

Near-realtime harvest filters **today→now** only. After blowup repair deletes bloated queue CSVs, past days that still exist as source logs under `/var/log` are **not** re-exported automatically.

**Menu:** Data → Automation → **Backfill Missing S3 Days**, or Troubleshoot → Storage → **Backfill missing S3 days**. Repair also offers this after a successful apply.

```sh
./scripts/data/automation/backfill_s3_days.sh                 # dry-run gap report
sudo ./scripts/data/automation/backfill_s3_days.sh --apply --flush
```

Compares local dated source logs vs sane (≤50 MiB) objects under the configured RACHEL/ModuleGaze S3 prefixes, builds day-scoped CSVs for gaps, enqueues with a hard size cap (never multi‑GiB junk), then flushes. Lists S3 via a temp file (not `aws | python` + heredoc) so coverage analysis cannot silently see 0 objects.

## Reliability safeguards

Failed transfers stay pending, interrupted/legacy failed items are recovered for retry, and the dispatcher checks again 60 seconds after an attempt ends. A failed file does not discard its payload or sidecars. Network calls and transfer attempts are bounded; large-file attempt deadlines scale with size. The configured upload window still applies.

Collection pauses below 5 GiB free or at 90% used, and resumes with at least 8 GiB free and no more than 85% used. It preserves source records and queued uploads. Queue payloads larger than `CDN_AUTO_MAX_QUEUE_FILE_BYTES` (default 100 MiB) are refused so a processor bug cannot re-fill the disk. Orphan `.*.tmp.*` enqueue copies are deleted whenever the queue is prepared. Skipping an already-completed/uploading basename still removes the processed workspace. The independent S3 cleanup timer runs after boot and six hours after each pass, with low CPU/disk priority. Verification happens outside the queue lock; deletion takes a brief nonblocking lock and rechecks file identity. Active uploads and mismatched/missing cloud copies are retained. Age alone never deletes queue payloads. Assessment delivery receipts preserve deduplication after verified cleanup.

`install-safeguards.sh` persists a 1 MB/s background upload limit and two transfer requests for the configured AWS profile. Full-content cleanup verification reads are capped at 256 KiB/s. Use `status.sh` for the collection-paused marker and last dispatch attempt/error.

Regression checks:

```sh
bash scripts/data/lib/test_resilience.sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/data/automation/test_verified_cleanup.py
```
