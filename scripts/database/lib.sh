#!/bin/bash
# Shared OC4D PostgreSQL backup/restore settings.
set -euo pipefail

OC4D_DB_CONTAINER="${OC4D_DB_CONTAINER:-oc4d_db}"
OC4D_DB_NAME="${OC4D_DB_NAME:-oc4d}"
OC4D_DB_USER="${OC4D_DB_USER:-postgres}"
OC4D_DB_BACKUP_DIR="${OC4D_DB_BACKUP_DIR:-/var/backups/oc4d/database}"
OC4D_DB_BACKUP_MAX="${OC4D_DB_BACKUP_MAX:-10}"
OC4D_WEB_SERVICE="${OC4D_WEB_SERVICE:-oc4d.service}"
LOG_DIR="/var/log/oc4d-db-backup"
LOG_FILE="$LOG_DIR/backup.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  local line="[$(ts)] $*"
  echo "$line"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

ensure_backup_dir() {
  local lib_dir
  lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=../lib/permissions.sh
  source "$lib_dir/../lib/permissions.sh"
  ensure_oc4d_backup_dirs "${SUDO_USER:-${USER:-pi}}"
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$OC4D_DB_CONTAINER"
}

ensure_container() {
  if container_running; then
    return 0
  fi
  log "ERROR: Container '$OC4D_DB_CONTAINER' is not running."
  return 1
}

backup_stamp() {
  date '+%Y-%m-%d_%H-%M-%S'
}

backup_basename() {
  echo "oc4d-backup-$(backup_stamp)"
}

# Human-readable label for menus and status (parses filename when possible).
format_backup_label() {
  local file="$1"
  local base
  base="$(basename "$file")"

  if [[ "$base" =~ ^oc4d-backup-([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})\.sql\.gz$ ]]; then
    printf '%s %s:%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    return 0
  fi
  if [[ "$base" =~ ^oc4d-([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.sql\.gz$ ]]; then
    printf '%s-%s-%s %s:%s:%s\n' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
    return 0
  fi
  if [[ "$base" =~ ^pre-restore-([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})\.sql\.gz$ ]]; then
    printf 'pre-restore %s %s:%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    return 0
  fi
  if [[ "$base" =~ ^pre-restore-([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.sql\.gz$ ]]; then
    printf 'pre-restore %s-%s-%s %s:%s:%s\n' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
    return 0
  fi

  date -r "$file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || stat -c '%y' "$file" 2>/dev/null | cut -d. -f1
}

list_backups() {
  find "$OC4D_DB_BACKUP_DIR" -maxdepth 1 -type f \( \
    -name 'oc4d-backup-*.sql.gz' -o \
    -name 'oc4d-????????_*.sql.gz' \
  \) -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | awk '{ $1=""; sub(/^ /, ""); print }'
}

rotate_backups() {
  local max="${1:-$OC4D_DB_BACKUP_MAX}"
  local files=()
  mapfile -t files < <(list_backups)
  if ((${#files[@]} <= max)); then
    return 0
  fi
  local idx
  for ((idx = max; idx < ${#files[@]}; idx++)); do
    rm -f "${files[$idx]}"
    log "Removed old backup: ${files[$idx]}"
  done
}
