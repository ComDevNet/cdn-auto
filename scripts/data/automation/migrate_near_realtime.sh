#!/bin/bash
# Run ON the Pi (after git pull). Installs harvester/dispatcher + near-realtime 15m.
# Usage: sudo ./scripts/data/automation/migrate_near_realtime.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."

if [[ "${EUID:-}" -ne 0 ]]; then
  echo "Run with sudo."
  exit 1
fi

NONINTERACTIVE=1 ./scripts/data/automation/install.sh

CONF=config/automation.conf
[[ -f "$CONF" ]] || { echo "missing $CONF — run configure interactively once"; exit 1; }

set_kv() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$CONF"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONF"
  else
    echo "${key}=\"${val}\"" >> "$CONF"
  fi
}

set_kv SCHEDULE_TYPE near_realtime
set_kv RUN_INTERVAL 900
set_kv HARVEST_INTERVAL 900
set_kv UPLOAD_WINDOW always

mkdir -p /etc/systemd/system/v5-log-harvester.timer.d /etc/systemd/system/v5-log-dispatcher.timer.d
printf '%s\n' '[Timer]' 'OnCalendar=' 'OnUnitActiveSec=' 'OnUnitActiveSec=900' 'Persistent=true' \
  >/etc/systemd/system/v5-log-harvester.timer.d/override.conf
printf '%s\n' '[Timer]' 'OnCalendar=' 'OnUnitActiveSec=' 'OnUnitActiveSec=900' 'Persistent=true' \
  >/etc/systemd/system/v5-log-dispatcher.timer.d/override.conf

systemctl daemon-reload
systemctl enable --now v5-log-harvester.timer v5-log-dispatcher.timer
systemctl stop v5-log-processor.timer 2>/dev/null || true
systemctl disable v5-log-processor.timer 2>/dev/null || true

echo "Migrated to near_realtime 15m (UPLOAD_WINDOW=always)."
echo "Check: ./scripts/data/automation/status.sh"
