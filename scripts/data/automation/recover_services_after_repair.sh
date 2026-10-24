#!/usr/bin/env bash
# Bring critical Pi services back after storage blowup repair (or standalone).
# Adaptive: only enable/start units and containers that exist on this device.
# Optionally restores Postgres from the newest NON-EMPTY sql.gz backup when the
# oc4d_db volume looks empty / unhealthy.
#
# Usage (from repo root):
#   ./scripts/data/automation/recover_services_after_repair.sh            # dry-run
#   ./scripts/data/automation/recover_services_after_repair.sh --apply
#   ./scripts/data/automation/recover_services_after_repair.sh --apply --restore-db
#   ./scripts/data/automation/recover_services_after_repair.sh --apply --restore-db --yes
#
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

APPLY=0
RESTORE_DB=0
YES=0
START_TIMERS=1
MIN_BACKUP_BYTES="${CDN_AUTO_MIN_DB_BACKUP_BYTES:-20480}"
MIN_PUBLIC_TABLES="${CDN_AUTO_MIN_DB_TABLES:-5}"
OC4D_DB_CONTAINER="${OC4D_DB_CONTAINER:-oc4d_db}"
OC4D_DB_USER="${OC4D_DB_USER:-postgres}"
OC4D_DB_NAME="${OC4D_DB_NAME:-oc4d}"
OC4D_DB_BACKUP_DIR="${OC4D_DB_BACKUP_DIR:-/var/backups/oc4d/database}"
COMPOSE_FILE="${OC4D_DB_COMPOSE_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --restore-db) RESTORE_DB=1 ;;
    --yes|-y) YES=1 ;;
    --no-timers) START_TIMERS=0 ;;
    --min-backup-bytes) MIN_BACKUP_BYTES="${2:?}"; shift ;;
    --compose-file) COMPOSE_FILE="${2:?}"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

log() { echo "[recover] $*"; }

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

unit_exists() {
  local unit="$1"
  # unit files, aliases, or generated units
  systemctl cat "$unit" >/dev/null 2>&1
}

unit_is_enabled() {
  local st
  st="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  [[ "$st" == "enabled" || "$st" == "enabled-runtime" || "$st" == "static" || "$st" == "indirect" ]]
}

ensure_unit() {
  local unit="$1"
  local mode="${2:-start}" # start | enable-now
  if ! unit_exists "$unit"; then
    log "SKIP (not installed): $unit"
    return 0
  fi
  if (( ! APPLY )); then
    if [[ "$mode" == "enable-now" ]]; then
      log "WOULD enable --now $unit (state: $(systemctl is-active "$unit" 2>/dev/null || echo n/a))"
    else
      log "WOULD start $unit (state: $(systemctl is-active "$unit" 2>/dev/null || echo n/a))"
    fi
    return 0
  fi
  if [[ "$mode" == "enable-now" ]]; then
    run_root systemctl enable --now "$unit" 2>/dev/null || run_root systemctl start "$unit" 2>/dev/null || true
  else
    run_root systemctl start "$unit" 2>/dev/null || true
  fi
  log "OK $unit → $(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
}

processor_safeguard_ok() {
  # Prefer starting timers only when queue size guard exists (post blowup fix).
  local helpers="$ROOT/scripts/data/lib/s3_helpers.sh"
  [[ -f "$helpers" ]] && grep -q 'CDN_AUTO_MAX_QUEUE_FILE_BYTES' "$helpers"
}

find_compose_file() {
  if [[ -n "$COMPOSE_FILE" && -f "$COMPOSE_FILE" ]]; then
    printf '%s\n' "$COMPOSE_FILE"
    return 0
  fi
  local candidates=(
    "$HOME/oc4d-server/workspaces/website/docker-compose.yml"
    "/home/pi/oc4d-server/workspaces/website/docker-compose.yml"
    "$ROOT/../oc4d-server/workspaces/website/docker-compose.yml"
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]] && grep -q 'oc4d_db\|oc4d-postgres' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    run_root docker "$@"
  fi
}

container_running() {
  docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "$OC4D_DB_CONTAINER"
}

container_exists() {
  docker_cmd ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$OC4D_DB_CONTAINER"
}

ensure_docker_and_db() {
  ensure_unit docker.service enable-now
  # containerd often ships with docker; start if present
  unit_exists containerd.service && ensure_unit containerd.service start

  if (( ! APPLY )); then
    if container_running; then
      log "oc4d_db already running"
    elif container_exists; then
      log "WOULD docker start $OC4D_DB_CONTAINER"
    else
      local compose
      if compose="$(find_compose_file)"; then
        log "WOULD compose up db from $compose"
      else
        log "WARN: $OC4D_DB_CONTAINER missing and no compose file found"
      fi
    fi
    return 0
  fi

  # Wait briefly for docker socket
  local i
  for i in 1 2 3 4 5; do
    if docker_cmd info >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if container_running; then
    log "oc4d_db already running"
    return 0
  fi

  if container_exists; then
    log "Starting existing container $OC4D_DB_CONTAINER…"
    docker_cmd start "$OC4D_DB_CONTAINER" >/dev/null || true
  fi

  if ! container_running; then
    local compose
    if compose="$(find_compose_file)"; then
      log "Bringing up db via compose: $compose"
      if command -v docker-compose >/dev/null 2>&1; then
        (cd "$(dirname "$compose")" && run_root docker-compose -f "$compose" up -d db) || \
          (cd "$(dirname "$compose")" && run_root docker-compose -f "$compose" up -d) || true
      else
        (cd "$(dirname "$compose")" && docker_cmd compose -f "$compose" up -d db) || \
          (cd "$(dirname "$compose")" && docker_cmd compose -f "$compose" up -d) || true
      fi
    fi
  fi

  if container_running; then
    log "OK $OC4D_DB_CONTAINER running"
  else
    log "WARN: could not start $OC4D_DB_CONTAINER"
  fi
}

db_public_table_count() {
  if ! container_running; then
    echo -1
    return 0
  fi
  local count
  count="$(docker_cmd exec "$OC4D_DB_CONTAINER" psql -U "$OC4D_DB_USER" -d "$OC4D_DB_NAME" -t -A \
    -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo "")"
  count="$(echo "$count" | tr -d '[:space:]')"
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    echo "$count"
  else
    echo -1
  fi
}

db_needs_restore() {
  local count
  count="$(db_public_table_count)"
  if (( count < 0 )); then
    return 0
  fi
  if (( count < MIN_PUBLIC_TABLES )); then
    return 0
  fi
  return 1
}

backup_is_usable() {
  local file="$1"
  local sz uncompressed
  [[ -f "$file" ]] || return 1
  sz="$(wc -c < "$file" | tr -d ' ')"
  [[ "$sz" =~ ^[0-9]+$ ]] || return 1
  (( sz >= MIN_BACKUP_BYTES )) || return 1
  # Reject empty / near-empty gzip payloads
  uncompressed="$(gzip -l "$file" 2>/dev/null | awk 'NR==2 {print $2}')"
  if [[ "$uncompressed" =~ ^[0-9]+$ ]] && (( uncompressed < 512 )); then
    return 1
  fi
  # Reject dumps that are basically empty (no CREATE/COPY)
  local sample
  sample="$(gunzip -c "$file" 2>/dev/null | head -c 200000 || true)"
  if ! echo "$sample" | grep -qE 'CREATE TABLE|COPY public\.|INSERT INTO'; then
    return 1
  fi
  return 0
}

latest_usable_backup() {
  local f
  if [[ ! -d "$OC4D_DB_BACKUP_DIR" ]]; then
    return 1
  fi
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if backup_is_usable "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
    log "SKIP tiny/empty backup: $(basename "$f")"
  done < <(
    find "$OC4D_DB_BACKUP_DIR" -maxdepth 1 -type f \( \
      -name 'oc4d-backup-*.sql.gz' -o \
      -name 'oc4d-????????_*.sql.gz' \
    \) -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn \
      | awk '{ $1=""; sub(/^ /, ""); print }'
  )
  return 1
}

verify_oc4d_http() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/api/system/info 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

maybe_restore_db() {
  local backup_file=""
  local tables
  tables="$(db_public_table_count)"
  log "DB public tables: $tables (min healthy: $MIN_PUBLIC_TABLES)"

  if ! db_needs_restore; then
    log "Database looks populated — no restore needed"
    return 0
  fi

  if ! backup_file="$(latest_usable_backup)"; then
    log "WARN: DB unhealthy/empty but no usable backup under $OC4D_DB_BACKUP_DIR"
    return 1
  fi

  log "Candidate restore: $(basename "$backup_file") ($(du -h "$backup_file" | awk '{print $1}'))"

  if (( ! RESTORE_DB )); then
    log "DB restore available but not requested (pass --restore-db, or confirm in menu)"
    return 2
  fi

  if (( ! APPLY )); then
    log "WOULD restore $backup_file via scripts/database/restore.sh"
    return 0
  fi

  if (( ! YES )); then
    log "ERROR: --restore-db with --apply requires --yes (menu supplies confirmation)"
    return 1
  fi

  local restore_script="$ROOT/scripts/database/restore.sh"
  if [[ ! -f "$restore_script" ]]; then
    log "ERROR: restore script missing: $restore_script"
    return 1
  fi

  log "Restoring database from $(basename "$backup_file")…"
  run_root bash "$restore_script" --file "$backup_file" --yes

  tables="$(db_public_table_count)"
  log "DB public tables after restore: $tables"
  if db_needs_restore; then
    log "WARN: DB still looks empty after restore"
    return 1
  fi
  return 0
}

start_critical_units() {
  # Order: runtime → db container → app → network helpers → companions → monitors
  ensure_docker_and_db

  # DB monitor after container attempt
  ensure_unit oc4d-db-monitor.service enable-now

  ensure_unit oc4d.service enable-now

  # Hotspot / mesh — start if unit exists (enabled state varies by device)
  ensure_unit hostapd.service start
  ensure_unit dnsmasq.service start
  ensure_unit zerotier-one.service enable-now
  ensure_unit start_hostapd.service start

  # Companion apps when present
  ensure_unit cdnmodulegaze.service enable-now
  ensure_unit modulegaze.service enable-now
  ensure_unit cdnsurvey.service enable-now
  ensure_unit modulefetch.service enable-now

  # Watchdogs last so they see recovering services
  ensure_unit service-monitor.service enable-now

  if (( START_TIMERS )); then
    if processor_safeguard_ok; then
      ensure_unit v5-log-harvester.timer enable-now
      ensure_unit v5-log-dispatcher.timer enable-now
      ensure_unit cdn-auto-s3-verified-cleanup.timer enable-now
      ensure_unit oc4d-db-backup.timer enable-now
    else
      log "WARN: queue size safeguard missing in s3_helpers.sh — leaving harvest timers alone"
      log "       Update cdn-auto / run Data → Automation → Install before starting timers"
    fi
  else
    log "Skipping automation timers (--no-timers)"
  fi
}

verify_summary() {
  echo
  log "—— Status summary ——"
  local u
  for u in \
    docker.service \
    oc4d.service \
    oc4d-db-monitor.service \
    service-monitor.service \
    cdnmodulegaze.service \
    v5-log-harvester.timer \
    v5-log-dispatcher.timer \
    hostapd.service \
    dnsmasq.service \
    zerotier-one.service
  do
    unit_exists "$u" || continue
    printf '  %-36s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo n/a)"
  done

  if container_running; then
    log "oc4d_db: running (public tables=$(db_public_table_count))"
  else
    log "oc4d_db: NOT running"
  fi

  if verify_oc4d_http; then
    log "OC4D HTTP: /api/system/info → 200"
  else
    if unit_exists oc4d.service; then
      log "WARN: OC4D HTTP check failed (service may still be starting, or DB empty)"
    fi
  fi
}

echo "=============================================="
echo " CDN-auto post-repair service recovery"
echo " Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo " Repo: $ROOT"
echo "=============================================="
echo

start_critical_units

# Give oc4d a moment after start before DB/HTTP checks
if (( APPLY )); then
  sleep 2
fi

db_rc=0
maybe_restore_db || db_rc=$?

verify_summary

echo
if (( ! APPLY )); then
  log "Dry-run only. Re-run with --apply after review."
  if (( db_rc == 2 )); then
    log "DB appears empty — use --apply --restore-db --yes (or menu confirm) to restore."
  fi
  exit 0
fi

log "Done."
exit 0
