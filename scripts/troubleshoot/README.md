# Troubleshoot

Tools for diagnosing common issues.

- [oc4d.sh](./oc4d.sh) — OC4D service checks
- [storage.sh](./storage.sh) — disk browse (`ncdu`) + **Repair storage blowup** (upload-queue / log reclaim)
- [wifi.sh](./wifi.sh) — Wi‑Fi diagnostics

## Storage blowup repair

Menu path: **Troubleshoot → Storage → Repair storage blowup**  
(Same tool: **Data → Automation → Repair Storage Blowup**)

Runs a dry-run of `../data/automation/repair_storage_blowup.sh`, then asks before deleting anything. Use on devices that filled the disk with multi‑GiB near-realtime CSVs. Install Automation does **not** run this silently; it may detect symptoms and offer the same interactive repair.

Inner workings

- Service checks call systemctl status and journalctl for logs
- Storage option 1 runs `ncdu /`; option 2 is the guided repair
- Wi‑Fi script inspects wlan interfaces and AP status
