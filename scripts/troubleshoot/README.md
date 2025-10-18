# Troubleshoot

Tools for diagnosing common issues.

- kolibri.sh — Kolibri service checks
- oc4d.sh — OC4D service checks
- storage.sh — storage space utility
- wifi.sh — Wi‑Fi diagnostics

Inner workings

- Service checks call systemctl status and journalctl for logs
- Storage checks run df -h and optionally du on key paths
- Wi‑Fi script inspects wlan interfaces and AP status
