# Troubleshoot

Tools for diagnosing common issues.

- [oc4d.sh](./oc4d.sh) — OC4D service checks
- [storage.sh](./storage.sh) — disk browse (`ncdu`), **Repair storage blowup**, **Recover services**, **Backfill missing S3 days**
- [wifi.sh](./wifi.sh) — Wi‑Fi diagnostics

## Storage blowup repair

Menu path: **Troubleshoot → Storage → Repair storage blowup**  
(Same tool: **Data → Automation → Repair Storage Blowup**)

Runs a dry-run of `../data/automation/repair_storage_blowup.sh`, then asks before deleting anything. Use on devices that filled the disk with multi‑GiB near-realtime CSVs. Install Automation does **not** run this silently; it may detect symptoms and offer the same interactive repair. After apply it offers **Recover services** (start units / docker / optional DB restore) and **Backfill missing S3 days** (near-realtime never re-exports past days).

## Recover services

Menu path: **Troubleshoot → Storage → Recover services**  
(Same tool: **Data → Automation → Recover Services**; also offered after storage-blowup repair)

Dry-run then confirm. Enables/starts units that exist on the device (`oc4d`, `docker`, `service-monitor`, harvest timers, `cdnmodulegaze`, hostapd/dnsmasq/zerotier, …), brings up `oc4d_db` via docker/compose when present, checks `/api/system/info`, and if the DB looks empty offers restore from the newest non-empty `/var/backups/oc4d/database/*.sql.gz` (skips tiny/empty dumps; confirm required).

## Backfill missing S3 days

Menu path: **Troubleshoot → Storage → Backfill missing S3 days**  
(Same tool: **Data → Automation → Backfill Missing S3 Days**)

Dry-run compares local `/var/log` source-log days vs sane S3 objects, then can rebuild day-scoped CSVs, enqueue (size-capped), and flush. See `../data/automation/README.md`.

Inner workings

- Service checks call systemctl status and journalctl for logs
- Storage: ncdu → repair → recover services → S3 day backfill
- Wi‑Fi script inspects wlan interfaces and AP status
