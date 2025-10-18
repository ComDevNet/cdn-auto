# VPN

Manage VPN connectivity.

- connect.sh — connect to VPN
- disconnect.sh — disconnect
- status.sh — check VPN status

Inner workings

- Scripts wrap the VPN CLI (e.g., openvpn/wg) and expose minimal connect/disconnect/status commands
- Check logs via journalctl if connections fail; network readiness affects success
