# System

Utilities for system configuration and maintenance.

- [networking.sh](./networking.sh) and [networking/](./networking/) — IP, interfaces, diagnostics
- [modem.sh](./modem.sh) — USB modem connect
- [wifi-name.sh](./wifi-name.sh) / [wifi-password.sh](./wifi-password.sh) — manage Wi‑Fi AP settings
- [raspi-config.sh](./raspi-config.sh) — run Raspberry Pi config
- [reboot.sh](./reboot.sh) / [shutdown.sh](./shutdown.sh) — power controls

Inner workings

- Networking tasks use ip and ifconfig where available; the networking/ folder may include helpers for routes and status
- Wi‑Fi name/password scripts edit hostapd configuration (files/hostapd_secure.conf)
- Commands are run with care; some actions may require sudo depending on the environment
