#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SERVICE_NAME="oc4d-db-backup"

echo "OC4D database backups"
echo "  Directory : $OC4D_DB_BACKUP_DIR"
echo "  Max kept  : $OC4D_DB_BACKUP_MAX"
echo "  Container : $OC4D_DB_CONTAINER"
echo ""

if systemctl list-unit-files "${SERVICE_NAME}.timer" >/dev/null 2>&1; then
  systemctl status "${SERVICE_NAME}.timer" --no-pager || true
else
  echo "Timer not installed. Use 'Install auto backup' from the database menu."
fi

echo ""
echo "Stored backups:"
ensure_backup_dir
files=()
mapfile -t files < <(list_backups)
if ((${#files[@]} == 0)); then
  echo "  (none yet)"
else
  for file in "${files[@]}"; do
    echo "  $(basename "$file")  $(du -h "$file" | awk '{print $1}')  $(date -r "$file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$file" 2>/dev/null | cut -d. -f1)"
  done
fi

echo ""
if [[ -f "$LOG_FILE" ]]; then
  echo "Recent log lines:"
  tail -n 10 "$LOG_FILE" || true
fi

read -rp "Press Enter to continue..."
