#!/bin/bash
# Install systemd timer: OC4D DB backup every 6 hours, keep 3 copies.
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run with sudo."
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SERVICE_NAME="oc4d-db-backup"
WRAPPER_SCRIPT="/usr/local/bin/run_oc4d_db_backup.sh"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/database/backup.sh"

ensure_backup_dir
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

systemctl stop "$SERVICE_NAME.timer" 2>/dev/null || true
systemctl disable "$SERVICE_NAME.timer" 2>/dev/null || true

tee "$WRAPPER_SCRIPT" >/dev/null <<EOF
#!/bin/bash
set -euo pipefail
echo "--- OC4D DB backup triggered at \$(date) ---"
exec "$BACKUP_SCRIPT" >> "$LOG_FILE" 2>&1
EOF
chmod +x "$WRAPPER_SCRIPT"

tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=Backup the OC4D PostgreSQL database
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$WRAPPER_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

tee "/etc/systemd/system/${SERVICE_NAME}.timer" >/dev/null <<EOF
[Unit]
Description=Run OC4D PostgreSQL backups every 6 hours
Requires=${SERVICE_NAME}.service

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.timer"
systemctl start "${SERVICE_NAME}.timer"

echo "Installed ${SERVICE_NAME}.timer (every 6 hours, max ${OC4D_DB_BACKUP_MAX} backups in ${OC4D_DB_BACKUP_DIR})."
echo "Manual backup: sudo $BACKUP_SCRIPT"
echo "Restore:       sudo $PROJECT_ROOT/scripts/database/restore.sh"
systemctl status "${SERVICE_NAME}.timer" --no-pager || true
