# Goal Prompt 1: Decouple CDN-auto harvest from upload (power-cycle safe)

Copy everything below the line into a coding agent.

Repos:
- Primary: `C:\Users\llewe\Documents\00-CODES\cdn-auto`
- Reference live edge box (optional): `ssh pi@192.168.1.214` (user `pi`) — host `cdn`, project `/home/pi/cdn-auto`
- Related cloud ingest (do not change charting here): `C:\Users\llewe\Documents\00-CODES\oc4d`

Observed on the live Pi (baseline):
- systemd: `v5-log-processor.timer` = `OnCalendar=daily` (next ~00:00)
- Config: `SCHEDULE_TYPE=daily`, `SERVER_VERSION=v6`, `DEVICE_LOCATION=teach-team-test`
- S3: `s3://oc4d-raw-reports` / `Testing`
- Stages enabled: ModuleGaze + OC4D assessments
- Queue dirs exist and are empty: `00_DATA/00_UPLOAD_QUEUE/{RACHEL,ModuleGaze,OC4DAssessments}`
- Entrypoint: `/usr/local/bin/run_v5_log_processor.sh` → oneshot service
- Status tooling already exists: `scripts/data/automation/status.sh`

---

## Goal

Make CDN-auto **collect whenever the device is on**, store results in a **durable local queue**, and **upload only during a configured upload window** (or when explicitly forced).

Today harvest + filter + upload are largely one scheduled oneshot. If the Pi is powered off at that window, on-period data can be missed or delayed. Offline queue exists, but there is no clean split between “gather data” and “send data.”

Destination remains **OC4D cloud via S3** (`oc4d-raw-reports` → Lambda). Do **not** POST analytics to oc4d-server. Local `http://127.0.0.1:3000` is only for pulling assessment results to harvest.

This is the **reliability foundation**. Near-realtime freshness (Goal Prompt 2) builds on it: frequent harvest + configurable upload cadence.

## User story

As an admin of edge devices that power off / go offline during the day,
I want CDN-auto to keep harvesting into a local queue while awake, and only upload in my chosen window,
So that activity from on-periods is not lost just because the device was off at “upload time.”

## Acceptance criteria

- [ ] AC1 Separate harvest from upload  
  Harvester runs on a short fixed interval while the device is on (default hourly; configurable).  
  Harvest succeeds without network. It only extracts/formats and enqueues.

- [ ] AC2 Durable pending queue  
  Extend (preferred) or replace `00_DATA/00_UPLOAD_QUEUE`.  
  Items have explicit state: `pending` / `uploading` / `completed` / `failed`.  
  Survives reboot and sudden power loss (atomic writes / WAL / crash-safe replace).

- [ ] AC3 Configurable upload window  
  Admin can set when uploads are allowed (daily at HH:MM, hour ranges, off-peak).  
  Harvest continues outside the window; dispatcher does not upload outside it (except manual flush).

- [ ] AC4 Batch upload in window  
  When window is open **and** online, dispatcher uploads pending items via existing S3 helpers, marks completed only after confirmed success.  
  Outside window → stay pending.

- [ ] AC5 Dedup + retry  
  Re-harvest must not duplicate the same logical payload/window.  
  Failed uploads stay pending for next window/retry.  
  Completed items purged/archived after retention.

- [ ] AC6 Operator visibility  
  Extend `status.sh` (and/or a small status JSON/CLI) to show: pending count by stage, last harvest OK, last upload OK, next upload window.  
  Full GUI optional.

## Implementation order

1. **Model the queue** — define item identity (stage + window stamp + content hash/key), states, and on-disk layout under `00_UPLOAD_QUEUE` (sidecars OK; SQLite OK if clearly better).
2. **Split runner** — extract harvest path (collect → process → filter → enqueue) from upload path (flush pending → S3).
3. **Two systemd units/timers**
   - `v5-log-harvester.timer` — frequent (default hourly)
   - `v5-log-dispatcher.timer` — evaluates upload schedule (or keep one timer that only uploads when window open)
4. **Config** — extend `automation.conf` + `configure.sh`:
   - `HARVEST_INTERVAL` / harvest schedule
   - `UPLOAD_SCHEDULE` / upload window (keep backward compat with `SCHEDULE_TYPE` where possible)
5. **Dedup** — stable keys so reruns between uploads are no-ops for already-queued windows.
6. **Crash safety** — atomic enqueue; never delete local source of truth until upload confirmed (or keep archived copy).
7. **Status** — update `status.sh` + docs in `automation/README.md`.
8. **Manual escape hatch** — keep/enhance `flush_queue.sh` as “upload now.”

## Key files

- `scripts/data/automation/{runner.sh,install.sh,configure.sh,status.sh,flush_queue.sh,main.sh,README.md}`
- `scripts/data/automation/{time_window.py,filter_time_based.py}`
- `scripts/data/lib/{s3_helpers.sh,oc4d_assessment_helpers.sh,cleanup_helpers.sh}`
- `config/automation.conf`
- Live install: `/etc/systemd/system/v5-log-processor.{service,timer}`, `/usr/local/bin/run_v5_log_processor.sh`

## Design constraints

- Keep stage isolation: RACHEL / ModuleGaze / OC4DAssessments each enqueue/upload independently.
- Keep S3 key layouts and org prefixes (`S3_SUBFOLDER` / `OC4D_PARENT_ORG`).
- Long backlog: chunk/compress oversized batches.
- Do not break Castle hourly behaviour elsewhere; this Pi is `daily` / `v6` / `Testing`.
- Power-off mid-harvest must not corrupt the queue.

## Out of scope

- Real-time streaming on every network blip
- OC4D dashboard auto-refresh / freshness UI (Goal Prompt 2)
- ZeroTier / server-metrics pipeline
- Changing oc4d-server itself (except reading local assessment API as today)

## Done when

- With network disabled, harvester still produces pending queue items for RACHEL and/or ModuleGaze/assessments as configured
- With upload window closed, pending items accumulate and are not uploaded
- When window opens (or flush forced) and online, pending items upload to `oc4d-raw-reports` and leave the pending set
- Sudden reboot during harvest does not leave a corrupted queue
- `status.sh` shows pending + last harvest/upload + next window
- Existing daily install on the reference Pi can be migrated/upgraded cleanly

Implement fully for the core harvest→queue→windowed upload path. No stubs.
