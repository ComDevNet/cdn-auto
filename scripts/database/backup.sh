#!/bin/bash
# Create a compressed PostgreSQL dump and keep at most OC4D_DB_BACKUP_MAX copies.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

ensure_backup_dir
ensure_container

stamp="$(date '+%Y%m%d_%H%M%S')"
tmp_file="$OC4D_DB_BACKUP_DIR/.oc4d-${stamp}.sql.gz.tmp"
final_file="$OC4D_DB_BACKUP_DIR/oc4d-${stamp}.sql.gz"

log "Starting backup of database '$OC4D_DB_NAME' from container '$OC4D_DB_CONTAINER'"

if ! docker exec "$OC4D_DB_CONTAINER" pg_dump \
  -U "$OC4D_DB_USER" \
  -d "$OC4D_DB_NAME" \
  --clean \
  --if-exists \
  | gzip -c > "$tmp_file"; then
  rm -f "$tmp_file"
  log "ERROR: pg_dump failed."
  exit 1
fi

mv -f "$tmp_file" "$final_file"
chmod 600 "$final_file"

size="$(du -h "$final_file" | awk '{print $1}')"
rotate_backups "$OC4D_DB_BACKUP_MAX"

log "Backup complete: $final_file ($size). Keeping latest $OC4D_DB_BACKUP_MAX backup(s)."
