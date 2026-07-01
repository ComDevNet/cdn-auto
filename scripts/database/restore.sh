#!/bin/bash
# Restore OC4D PostgreSQL from a backup created by backup.sh.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [--file /path/to/oc4d-YYYYMMDD_HHMMSS.sql.gz] [--list]

  --list          List available backups and exit
  --file PATH     Restore the given backup without prompting
  -h, --help      Show this help
EOF
}

pick_backup_interactive() {
  local files=()
  mapfile -t files < <(list_backups)
  if ((${#files[@]} == 0)); then
    log "No backups found in $OC4D_DB_BACKUP_DIR"
    exit 1
  fi

  if command -v whiptail >/dev/null 2>&1; then
    local options=() file label
    for file in "${files[@]}"; do
      label="$(basename "$file") ($(du -h "$file" | awk '{print $1}'))"
      options+=("$file" "$label")
    done
    whiptail --title "Restore OC4D database" \
      --menu "Choose a backup to restore. This replaces the current database." 20 90 10 \
      "${options[@]}"
    return
  fi

  local idx=1
  echo "Available backups:"
  for file in "${files[@]}"; do
    echo "  $idx) $(basename "$file") ($(du -h "$file" | awk '{print $1}'))"
    idx=$((idx + 1))
  done
  local choice
  read -rp "Choose backup [1-${#files[@]}]: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
    echo "Invalid choice."
    exit 1
  fi
  echo "${files[$((choice - 1))]}"
}

confirm_restore() {
  local backup_file="$1"
  local prompt="Restore $(basename "$backup_file")? This replaces the current '$OC4D_DB_NAME' database."
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --yesno "$prompt" 12 80
    return
  fi
  read -rp "$prompt [y/N]: " yn
  [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
}

restore_from_file() {
  local backup_file="$1"

  if [[ ! -f "$backup_file" ]]; then
    log "ERROR: Backup not found: $backup_file"
    exit 1
  fi

  ensure_container

  local pre_restore="$OC4D_DB_BACKUP_DIR/pre-restore-$(date '+%Y%m%d_%H%M%S').sql.gz"
  log "Creating pre-restore snapshot: $pre_restore"
  docker exec "$OC4D_DB_CONTAINER" pg_dump \
    -U "$OC4D_DB_USER" \
    -d "$OC4D_DB_NAME" \
    --clean \
    --if-exists \
    | gzip -c > "$pre_restore"
  chmod 600 "$pre_restore"

  local stopped_web=0
  if systemctl is-active --quiet "$OC4D_WEB_SERVICE" 2>/dev/null; then
    log "Stopping $OC4D_WEB_SERVICE while the database is restored..."
    systemctl stop "$OC4D_WEB_SERVICE"
    stopped_web=1
  fi

  log "Restoring from $(basename "$backup_file")..."
  if ! gunzip -c "$backup_file" | docker exec -i "$OC4D_DB_CONTAINER" \
    psql -U "$OC4D_DB_USER" -d postgres -v ON_ERROR_STOP=1 >/dev/null; then
    log "ERROR: Restore failed. Pre-restore snapshot kept at $pre_restore"
    if (( stopped_web )); then
      systemctl start "$OC4D_WEB_SERVICE" || true
    fi
    exit 1
  fi

  if (( stopped_web )); then
    log "Starting $OC4D_WEB_SERVICE..."
    systemctl start "$OC4D_WEB_SERVICE" || log "WARN: Could not start $OC4D_WEB_SERVICE"
  fi

  log "Restore complete from $(basename "$backup_file")."
  log "Pre-restore snapshot: $pre_restore"
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

backup_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      backup_file="${2:-}"
      shift 2
      ;;
    --list)
      ensure_backup_dir
      list_backups
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

ensure_backup_dir

if [[ -z "$backup_file" ]]; then
  if ! backup_file="$(pick_backup_interactive)"; then
    echo "Restore cancelled."
    exit 0
  fi
fi

confirm_restore "$backup_file" || { echo "Restore cancelled."; exit 0; }
restore_from_file "$backup_file"
