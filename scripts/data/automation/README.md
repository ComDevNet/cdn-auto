# Automation (Harvester + Dispatcher)

CDN-auto **harvests whenever the device is on** into a durable local queue, and **uploads only during a configured upload window** (or when you force-flush).

Why systemd?

Reliable scheduling, dependency handling, `journalctl` logging, and no interactive session required.

Key features

- Separate harvester + dispatcher systemd timers (power-cycle safe)
- Harvest works offline: collect → process → filter → enqueue only
- Durable queue under `00_DATA/00_UPLOAD_QUEUE/{stage}/{pending,uploading,completed,failed}/`
- Configurable `UPLOAD_WINDOW` (always, HH:MM-HH:MM, overnight ranges)
- Dedup by payload basename / OC4D result id; crash recovery for interrupted uploads
- Stage-isolated RACHEL / ModuleGaze / OC4DAssessments
- Status shows pending counts, last harvest/upload, upload window
- Dual logging to `journalctl` and `/var/log/v5_log_processor/automation.log`

Components

- `main.sh` - menu: Install, Status, Configure, Flush Upload Queue
- `install.sh` - installs `v5-log-harvester` + `v5-log-dispatcher` (migrates off legacy `v5-log-processor`)
- `configure.sh` - writes `config/automation.conf`, harvest interval, upload window, S3 settings
- `runner.sh harvest|dispatch|all` - harvest enqueues; dispatch uploads when window open + online
- `status.sh` - timers, queue states, connectivity, AWS identity
- `flush_queue.sh` - force upload now (`FORCE_UPLOAD=1`, bypasses window)
- `filter_time_based.py` - builds final CSVs for the filter window (`SCHEDULE_TYPE`)
- `scripts/data/lib/s3_helpers.sh` - S3 upload + durable queue helpers
- `scripts/data/lib/cleanup_helpers.sh` - safe removal of raw/processed run folders
- `scripts/data/lib/oc4d_assessment_helpers.sh` - OC4D key/upload/queue helpers

Configuration (`config/automation.conf`)

- Existing keys unchanged (`SERVER_VERSION`, `DEVICE_LOCATION`, S3/OC4D settings, …)
- `SCHEDULE_TYPE` / `RUN_INTERVAL` — **data filter window** (which rows go into each CSV). Castle may use `hourly`.
- `HARVEST_INTERVAL` — how often the harvester runs while the device is on (seconds, default `3600`)
- `UPLOAD_WINDOW` — when the dispatcher may upload: `always` or `HH:MM-HH:MM` (overnight OK, e.g. `22:00-06:00`). Default for daily filter installs: `00:00-01:00`.

Data flow

1. **Harvester** (`runner.sh harvest`, timer `v5-log-harvester`)
   - Collects/processes/filters RACHEL, ModuleGaze, OC4D assessments as configured
   - Always enqueues into `…/pending/` (no network required)
   - Writes `.last_harvest_ok`

2. **Dispatcher** (`runner.sh dispatch`, timer `v5-log-dispatcher`, hourly check)
   - If outside `UPLOAD_WINDOW` → leave pending
   - If online and window open → upload pending → `completed/` (failures stay `pending/`)
   - Writes `.last_upload_ok` on full success

3. **Force flush** — `flush_queue.sh` bypasses the window

Queue layout

```
00_DATA/00_UPLOAD_QUEUE/
  RACHEL/{pending,uploading,completed,failed}/
  ModuleGaze/{pending,uploading,completed,failed}/
  OC4DAssessments/{pending,uploading,completed,failed}/
  .last_harvest_ok
  .last_upload_ok
```

Legacy flat files under a stage dir (or queue root) are migrated into `pending/` on the next prepare.

Where things live

- Config: `config/automation.conf`
- Queue: `00_DATA/00_UPLOAD_QUEUE/`
- Logs: `/var/log/v5_log_processor/automation.log`
- Journal: `journalctl -u v5-log-harvester.service -u v5-log-dispatcher.service`

Commands

- Install: `sudo ./scripts/data/automation/install.sh`
- Configure: `sudo ./scripts/data/automation/configure.sh`
- Status: `./scripts/data/automation/status.sh`
- Flush now: `./scripts/data/automation/flush_queue.sh`
- Manual harvest: `sudo /usr/local/bin/run_v5_log_harvester.sh`
- Manual dispatch: `sudo /usr/local/bin/run_v5_log_dispatcher.sh`
- Legacy all-in-one: `sudo /usr/local/bin/run_v5_log_processor.sh` → `runner.sh all`

Migration (existing Pi on daily `v5-log-processor`)

1. Pull this code on the device
2. Run **Install Automation** (replaces legacy timer with harvester + dispatcher)
3. Run **Configure** (sets `HARVEST_INTERVAL` + `UPLOAD_WINDOW`; keeps `SCHEDULE_TYPE` as filter)
4. Confirm with **Status**

Troubleshooting

- Status shows pending by stage and whether the upload window is configured
- Outside the window, pending items accumulate until the window opens or you flush
- Interrupted uploads left in `uploading/` are recovered back to `pending/` on the next prepare
- Completed payloads older than `QUEUE_COMPLETED_RETENTION_DAYS` (default 7) are purged on flush
