#!/usr/bin/env bash
# Reclaim disk filled by the pre-bcd3831 near-realtime CSV re-import bug and
# related automation-log growth. Safe defaults: dry-run. Use --apply to delete.
#
# Cause (wisdom-homeschooling / similar):
#   Old processors merged every *.csv in 00_PROCESSED (including prior
#   *_access_logs.csv exports) into summary.csv. Each harvest roughly doubled
#   the export until pending/uploading held multi-GiB CSVs while /var/log/oc4d
#   stayed tens of MiB. Source logs are authoritative; bloated queue CSVs are not.
#
# Usage (from repo root, usually as root or pi with sudo):
#   ./scripts/data/automation/repair_storage_blowup.sh           # dry-run
#   ./scripts/data/automation/repair_storage_blowup.sh --apply
#   ./scripts/data/automation/repair_storage_blowup.sh --apply --max-mb 50
#
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

APPLY=0
DETECT=0
MAX_MB="${CDN_AUTO_REPAIR_MAX_MB:-100}"
STOP_TIMERS=1
VACUUM_JOURNAL=0
TRUNCATE_LOG_MB=50
PURGE_ALL_NR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --detect) DETECT=1 ;;
    --max-mb) MAX_MB="${2:?}"; shift ;;
    --no-stop-timers) STOP_TIMERS=0 ;;
    --vacuum-journal) VACUUM_JOURNAL=1 ;;
    --truncate-log-mb) TRUNCATE_LOG_MB="${2:?}"; shift ;;
    # Remove every near-realtime RACHEL/ModuleGaze export in the queue (any size).
    # Use on devices that already exploded; source /var/log/* regenerates correct CSVs.
    --purge-all-nr-exports) PURGE_ALL_NR=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if ! [[ "$MAX_MB" =~ ^[0-9]+$ ]] || (( MAX_MB < 1 )); then
  echo "Invalid --max-mb: $MAX_MB" >&2
  exit 2
fi

MAX_BYTES=$((MAX_MB * 1024 * 1024))
QUEUE_DIR="${CDN_AUTO_QUEUE_DIR:-$ROOT/00_DATA/00_UPLOAD_QUEUE}"
PROCESSED_ROOT="${CDN_AUTO_PROCESSED_ROOT:-$ROOT/00_DATA/00_PROCESSED}"
DATA_DIR="${CDN_AUTO_DATA_DIR:-$ROOT/00_DATA}"
LOG_FILE="${CDN_AUTO_LOG_FILE:-/var/log/v5_log_processor/automation.log}"
BACKUP_DIR="${CDN_AUTO_BACKUP_DIR:-/home/pi/cdn-auto-backups}"
HARVESTER_TIMER="${CDN_AUTO_HARVESTER_TIMER:-v5-log-harvester.timer}"
DISPATCHER_TIMER="${CDN_AUTO_DISPATCHER_TIMER:-v5-log-dispatcher.timer}"
CLEANUP_TIMER="${CDN_AUTO_CLEANUP_TIMER:-cdn-auto-s3-cleanup.timer}"

# --detect: exit 0 if blowup symptoms exist, 1 if clean (for install/menu prompts).
if (( DETECT )); then
  found=0
  if [[ -d "$QUEUE_DIR" ]]; then
    if find "$QUEUE_DIR" -type f -name '.*.tmp.*' -print -quit 2>/dev/null | grep -q .; then
      echo "[detect] orphan enqueue .tmp files under upload queue"
      found=1
    fi
    if find "$QUEUE_DIR" \( -path '*/RACHEL/*' -o -path '*/ModuleGaze/*' \) \
      -type f \( -name '*_access_logs.csv' -o -name '*_modulegaze_logs.csv' \) \
      -size "+${MAX_MB}M" -print -quit 2>/dev/null | grep -q .; then
      echo "[detect] queue CSV larger than ${MAX_MB} MiB (likely re-import blowup)"
      found=1
    fi
  fi
  if [[ -d "$PROCESSED_ROOT" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      sz="$(du -sm "$d" 2>/dev/null | awk '{print $1}')"
      if [[ "${sz:-0}" =~ ^[0-9]+$ ]] && (( sz > MAX_MB )); then
        echo "[detect] bloated processed folder (${sz} MiB): $(basename "$d")"
        found=1
        break
      fi
    done < <(find "$PROCESSED_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*_logs_*' -print 2>/dev/null)
  fi
  if [[ -f "$LOG_FILE" ]]; then
    log_sz="$(wc -c < "$LOG_FILE" | tr -d ' ')"
    if [[ "$log_sz" =~ ^[0-9]+$ ]] && (( log_sz > TRUNCATE_LOG_MB * 1024 * 1024 )); then
      echo "[detect] automation.log larger than ${TRUNCATE_LOG_MB} MiB"
      found=1
    fi
  fi
  if (( found )); then
    echo "[detect] symptoms present — run Troubleshoot → Storage → Repair, or Automation → Repair Storage Blowup"
    exit 0
  fi
  echo "[detect] no storage-blowup symptoms"
  exit 1
fi

freed_bytes=0
actions=0

log() { echo "[repair] $*"; }

bytes_of() {
  local f="$1"
  if [[ -f "$f" ]]; then
    wc -c < "$f" | tr -d ' '
  else
    echo 0
  fi
}

human() {
  local b="$1"
  if (( b >= 1073741824 )); then
    awk -v b="$b" 'BEGIN { printf "%.1f GiB", b/1073741824 }'
  elif (( b >= 1048576 )); then
    awk -v b="$b" 'BEGIN { printf "%.1f MiB", b/1048576 }'
  else
    echo "${b} B"
  fi
}

do_rm() {
  local path="$1"
  local why="$2"
  local sz
  sz="$(bytes_of "$path")"
  if (( APPLY )); then
    rm -f -- "$path" "${path}.cdnrun" "${path}.oc4dkey" "${path}.s3receipt" 2>/dev/null || true
    log "DELETED ($(human "$sz")) $why — $path"
  else
    log "WOULD DELETE ($(human "$sz")) $why — $path"
  fi
  freed_bytes=$((freed_bytes + sz))
  actions=$((actions + 1))
}

do_rm_rf() {
  local path="$1"
  local why="$2"
  local sz
  if [[ ! -d "$path" ]]; then
    return 0
  fi
  sz="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
  sz="${sz:-0}"
  if (( APPLY )); then
    rm -rf -- "$path"
    log "DELETED DIR ($(human "$sz")) $why — $path"
  else
    log "WOULD DELETE DIR ($(human "$sz")) $why — $path"
  fi
  freed_bytes=$((freed_bytes + sz))
  actions=$((actions + 1))
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

echo "=============================================="
echo " CDN-auto storage blowup repair"
echo " Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo " Max queue/export CSV: ${MAX_MB} MiB"
echo " Repo: $ROOT"
echo "=============================================="
df -h / "$DATA_DIR" 2>/dev/null || df -h /
echo

if (( STOP_TIMERS )); then
  if (( APPLY )); then
    log "Stopping automation timers and stuck uploads…"
    run_root systemctl stop "$HARVESTER_TIMER" "$DISPATCHER_TIMER" "$CLEANUP_TIMER" 2>/dev/null || true
    run_root systemctl stop v5-log-harvester.service v5-log-dispatcher.service 2>/dev/null || true
    # Kill bandwidth-wasting uploads of bloated CSVs (source logs remain).
    pkill -f 'aws .* s3 cp .*00_UPLOAD_QUEUE' 2>/dev/null || true
    sleep 1
  else
    log "WOULD stop $HARVESTER_TIMER / $DISPATCHER_TIMER / aws s3 cp of queue payloads"
  fi
fi

# 1) Orphan enqueue temps
if [[ -d "$QUEUE_DIR" ]]; then
  while IFS= read -r -d '' f; do
    do_rm "$f" "orphan enqueue temp"
  done < <(find "$QUEUE_DIR" -type f -name '.*.tmp.*' -print0 2>/dev/null)
fi

# 2) Bloated / suspect RACHEL / ModuleGaze queue payloads
if [[ -d "$QUEUE_DIR" ]]; then
  if (( PURGE_ALL_NR )); then
    while IFS= read -r -d '' f; do
      do_rm "$f" "near-realtime export purge (regenerate after update)"
    done < <(
      find "$QUEUE_DIR" \( -path '*/RACHEL/*' -o -path '*/ModuleGaze/*' \) \
        -type f \( -name '*_nr_*_access_logs.csv' -o -name '*_nr_*_modulegaze_logs.csv' \) \
        -print0 2>/dev/null
    )
  fi
  while IFS= read -r -d '' f; do
    do_rm "$f" "oversized queue CSV (>${MAX_MB} MiB; re-import blowup)"
  done < <(
    find "$QUEUE_DIR" \( -path '*/RACHEL/*' -o -path '*/ModuleGaze/*' \) \
      -type f \( -name '*_access_logs.csv' -o -name '*_modulegaze_logs.csv' \) \
      -size "+${MAX_MB}M" -print0 2>/dev/null
  )
fi

# 3) Bloated processed workspaces (summary + leftover filtered exports)
if [[ -d "$PROCESSED_ROOT" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    do_rm_rf "$d" "bloated processed run (will regenerate after update)"
  done < <(
    find "$PROCESSED_ROOT" -mindepth 1 -maxdepth 1 -type d \
      \( -name '*_logs_*' -o -name '*_modulegaze_logs_*' \) -print 2>/dev/null \
      | while read -r d; do
          sz="$(du -sm "$d" 2>/dev/null | awk '{print $1}')"
          [[ "${sz:-0}" =~ ^[0-9]+$ ]] && (( sz > MAX_MB )) && printf '%s\n' "$d"
        done
  )
  while IFS= read -r -d '' f; do
    do_rm "$f" "leftover filtered export in processed/"
  done < <(
    find "$PROCESSED_ROOT" -type f \
      \( -name '*_access_logs.csv' -o -name '*_modulegaze_logs.csv' -o -name 'temp_filtered.csv' \) \
      -size "+${MAX_MB}M" -print0 2>/dev/null
  )
fi

# 4) Stale raw collect folders under 00_DATA (not queue/processed)
if [[ -d "$DATA_DIR" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    base="$(basename "$d")"
    case "$base" in
      00_PROCESSED|00_UPLOAD_QUEUE|00_OC4D_ASSESSMENTS|.*) continue ;;
    esac
    do_rm_rf "$d" "stale raw collect folder"
  done < <(
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -name '*_logs_*' -print 2>/dev/null \
      | while read -r d; do
          sz="$(du -sm "$d" 2>/dev/null | awk '{print $1}')"
          [[ "${sz:-0}" =~ ^[0-9]+$ ]] && (( sz > MAX_MB )) && printf '%s\n' "$d"
        done
  )
fi

# 5) Automation log
if [[ -f "$LOG_FILE" ]]; then
  log_sz="$(bytes_of "$LOG_FILE")"
  trunc_bytes=$((TRUNCATE_LOG_MB * 1024 * 1024))
  if (( log_sz > trunc_bytes )); then
    if (( APPLY )); then
      : > "$LOG_FILE" 2>/dev/null || run_root truncate -s 0 "$LOG_FILE"
      log "TRUNCATED automation.log was $(human "$log_sz")"
    else
      log "WOULD TRUNCATE automation.log ($(human "$log_sz"))"
    fi
    freed_bytes=$((freed_bytes + log_sz))
    actions=$((actions + 1))
  fi
fi

# 6) Unbounded cleanup audit JSONLs
if [[ -d "$BACKUP_DIR" ]]; then
  while IFS= read -r -d '' f; do
    # Keep the newest 5 audit files
    :
  done < <(true)
  mapfile -t audits < <(ls -1t "$BACKUP_DIR"/s3-verified-cleanup-*.jsonl 2>/dev/null || true)
  if ((${#audits[@]} > 5)); then
    for f in "${audits[@]:5}"; do
      do_rm "$f" "old S3 cleanup audit"
    done
  fi
fi

# 7) Optional journal vacuum
if (( VACUUM_JOURNAL )); then
  if (( APPLY )); then
    log "Vacuuming journal to 100M…"
    run_root journalctl --vacuum-size=100M || true
  else
    log "WOULD journalctl --vacuum-size=100M"
  fi
fi

echo
df -h / "$DATA_DIR" 2>/dev/null || df -h /
echo
log "Actions: $actions | Reclaimable/freed ≈ $(human "$freed_bytes")"
if (( ! APPLY )); then
  echo
  log "Dry-run only. Re-run with --apply after review."
  log "Then update cdn-auto (pull through bcd3831+) and: sudo ./scripts/data/automation/install.sh"
  log "Source /var/log/oc4d (etc.) was not touched; harvest will rebuild correct CSVs."
  exit 0
fi

if (( STOP_TIMERS )); then
  log "Leaving timers STOPPED so you can update before harvest runs again."
  log "After git pull + install.sh: sudo systemctl start $HARVESTER_TIMER $DISPATCHER_TIMER"
fi
log "Done."
