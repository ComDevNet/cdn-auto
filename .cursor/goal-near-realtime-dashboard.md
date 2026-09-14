# Goal Prompt 2: Near-realtime field data on OC4D dashboard (cdn-auto + cloud)

Copy everything below the line into a coding agent.

Repos:
- Edge: `C:\Users\llewe\Documents\00-CODES\cdn-auto`
- Cloud: `C:\Users\llewe\Documents\00-CODES\oc4d`
- Reference live edge box (optional): `ssh pi@192.168.1.214` (user `pi`) — host `cdn`, `/home/pi/cdn-auto`

Observed on the live Pi (baseline):
- `v5-log-processor.timer` runs **daily** at midnight
- `SCHEDULE_TYPE=daily` → `time_window.py` uses **yesterday only** (completed day)
- Org/prefix: `Testing` on `s3://oc4d-raw-reports`
- ModuleGaze + OC4D assessments enabled
- This is exactly the “~1 day behind” problem

**Relationship to Goal Prompt 1:**  
Prompt 1 = don’t lose data across power cycles (harvest often, upload on a window).  
Prompt 2 = make the upload window / data window **fresh enough** that OC4D dashboards feel near-realtime-ish (~15–30 min with uplink), and show freshness in the UI.  
Prefer implementing Prompt 1 first (or at least the harvest/upload split), then use a **short upload window** (15–60 min) as the near-realtime schedule — not a third ad-hoc timer design.

---

## Goal

Make the analytics path feel near-realtime-ish:

`cdn-auto harvest → (queue) → S3 oc4d-raw-reports → Lambda → DynamoDB → OC4D dashboard`

So org/ops admins see today’s usage and assessment activity within minutes while the day is in progress — not tomorrow after the daily batch.

This is **not** ZeroTier/server-metrics live polling (already near-live). Do not route CSV upload over ZeroTier.

## User story

As a CDN/ops or org admin on the OC4D cloud dashboard,
I want field usage and assessment data to appear soon after it happens on site,
So I can monitor activity during the day without waiting for yesterday’s batch.

## Acceptance criteria

- [ ] AC1 Faster field delivery (cdn-auto)  
  Non-Castle sites can run near-realtime schedules (e.g. every 15–60 minutes), not only daily/weekly/monthly.  
  Uploaded windows include **current/incomplete** activity (rolling recent window), not only “yesterday / last completed period.”  
  Castle hourly remains supported; slower schedules remain available.

- [ ] AC2 Offline resilience  
  No uplink → queue (Prompt 1 queue or existing `00_UPLOAD_QUEUE`).  
  Connectivity returns → flush without manual steps; cloud shows data after ingest.

- [ ] AC3 Event-driven cloud ingest  
  Keep S3 `OBJECT_CREATED` → `csv-report-generator-triggered` Lambda → DynamoDB.  
  Record usable freshness (`lastUploadedAt` / ingest timestamp), not only metric day key.

- [ ] AC4 Dashboard near-live UX  
  Usage / relevant assessment views auto-refresh or otherwise pick up new data (poll ~1–5 min or refresh after ingest).  
  Show freshness: last upload / last ingest time (“live-ish” vs stale).

- [ ] AC5 Streams in v1  
  RACHEL/OC4D usage, ModuleGaze, OC4D assessment uploads from cdn-auto.  
  Explicitly document Kolibri in or out (outside cdn-auto today → default **out** unless pulled in).

- [ ] AC6 Cost / safety  
  No full-history re-upload every tick (delta/windowed only).  
  Preserve `{Org}/…` S3 isolation.  
  Failures visible (queue/status/logs/dashboard stale state).

**Suggested SLA:** with uplink, new field activity visible in OC4D cloud within **~15–30 minutes**.

## Implementation order

### A. cdn-auto (edge)
1. Allow near-realtime schedules for normal sites (not Castle-only hourly).
2. Change `time_window.py` / `filter_time_based.py` so near-realtime modes cover **rolling current window** (e.g. last N minutes / current incomplete hour), not only prior completed day.
3. Wire harvest+dispatch (from Prompt 1) so frequent harvest + frequent upload window = near-realtime; or frequent harvest + nightly window = bandwidth-safe.
4. Ensure queue flush on reconnect is prompt and stage-isolated.
5. Upgrade path for the reference Pi (`teach-team-test` / `Testing` / daily → optional 15–60 min mode for validation).

### B. OC4D cloud
1. Confirm/keep Lambda trigger freshness on each put.
2. Persist/expose ingest freshness metadata to the dashboard API.
3. Dashboard: optional auto-refresh + clear “last data / last ingest” display (similar spirit to server-metrics polling, but for analytics).
4. No websocket rewrite required for v1.

## Key files

**cdn-auto**
- `scripts/data/automation/{runner.sh,configure.sh,install.sh,status.sh,time_window.py,filter_time_based.py,README.md}`
- `scripts/data/lib/{s3_helpers.sh,oc4d_assessment_helpers.sh}`
- `config/automation.conf` (`SCHEDULE_TYPE`, `RUN_INTERVAL`, buckets, org prefix)

**oc4d**
- `workspaces/infra/lib/lambda/csv-report-generator-triggered.ts`
- Stack trigger in `workspaces/infra/lib/oc4d-stack.ts`
- Dashboard: `workspaces/website/app/dashboard/page.tsx` (+ related hooks/data fetch)
- Compare polling patterns: server-metrics hooks (inspiration only)

## Design constraints

- S3 remains transport.
- Compose with Prompt 1: do not invent a second competing queue.
- Delta uploads only; guard Lambda/S3 cost.
- Reference Pi validation: after change, a known local activity (module use / assessment) should appear in OC4D `Testing` within the SLA when uplink is up.

## Out of scope

- True websocket dashboards for every chart
- CSV over ZeroTier
- Replacing live server-metrics / ZT monitoring
- Full Kolibri pipeline rewrite (unless explicitly in scope)
- Sub-minute latency guarantees on bad field links

## Done when

- A non-Castle site can be configured for 15–60 min delivery of **current** activity
- Reference Pi upgraded/tested: activity shows in OC4D cloud within ~15–30 min when online
- Offline then reconnect flushes queued data automatically
- Dashboard shows freshness and updates without a full manual “leave and come back” ritual
- Daily/weekly/monthly and Castle hourly still work
- No cross-org prefix leakage; no full historical re-ingest each tick

Implement edge + cloud pieces needed for the SLA. No stubs on the critical path.
