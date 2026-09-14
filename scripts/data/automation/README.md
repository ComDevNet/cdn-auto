# Automation (Harvester + Dispatcher)

CDN-auto **harvests whenever the device is on** into a durable local queue, and **uploads only during a configured upload window** (or when you force-flush).

Near-realtime: choose **Near-realtime every 15/30/60 min** in Configure. That sets `SCHEDULE_TYPE=near_realtime` (rolling current bucket including incomplete activity), `HARVEST_INTERVAL`/`RUN_INTERVAL` to match, and `UPLOAD_WINDOW=always` so dispatch runs on the same cadence.

Streams in v1: RACHEL usage, ModuleGaze, OC4D assessments. **Kolibri is out** (not produced by cdn-auto).

## Key features

- Separate harvester + dispatcher systemd timers (power-cycle safe)
- Harvest works offline: collect → process → filter → enqueue only
- Durable queue under `00_DATA/00_UPLOAD_QUEUE/{stage}/{pending,uploading,completed,failed}/`
- Configurable `UPLOAD_WINDOW` (`always` or `HH:MM-HH:MM`)
- Near-realtime rolling windows for non-Castle sites (15–60 min)
- Dedup by payload basename / OC4D result id; crash recovery for interrupted uploads
- Stage-isolated RACHEL / ModuleGaze / OC4DAssessments

## Config highlights

- `SCHEDULE_TYPE`: `near_realtime` | `daily` | `weekly` | `monthly` | `yearly` | `custom` | Castle-only `hourly`
- `RUN_INTERVAL` / `HARVEST_INTERVAL`: seconds (near-realtime presets: 900 / 1800 / 3600)
- `UPLOAD_WINDOW`: `always` or `HH:MM-HH:MM` (near-realtime forces `always`)

## Commands

- Install: `sudo ./scripts/data/automation/install.sh`
- Configure: `sudo ./scripts/data/automation/configure.sh`
- Status: `./scripts/data/automation/status.sh`
- Flush now: `./scripts/data/automation/flush_queue.sh`
- Manual harvest / dispatch: `/usr/local/bin/run_v5_log_harvester.sh` / `run_v5_log_dispatcher.sh`

## Pi validation (near-realtime)

One-shot after `git pull` (existing `config/automation.conf`):

```bash
sudo ./scripts/data/automation/migrate_near_realtime.sh
./scripts/data/automation/status.sh
```

Or: Install + Configure → Near-realtime 15/30/60 min.

Then generate local activity (module use / assessment). Within ~15–30 min (with uplink), data should appear under the org prefix in `oc4d-raw-reports` and on the OC4D dashboard. Offline: pending accumulates; reconnect + dispatcher flush without manual steps.
