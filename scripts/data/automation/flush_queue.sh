#!/bin/bash
# Flush queued CSV uploads for both RACHEL and Kolibri destinations.
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

source "$PROJECT_ROOT/scripts/data/lib/s3_helpers.sh"

load_config() {
  local src="$CONFIG_FILE"
  local tmp=""
  if [[ -r "$src" ]]; then
    source "$src"
    log "[config] Loaded (direct): $src"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="/tmp/cdn_auto_conf.$$"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp"
      source "$tmp"
      rm -f "$tmp"
      log "[config] Loaded (sudo): $src"
      return 0
    fi
  fi
  log "[error] Cannot read config: $src"
  exit 1
}
load_config

QUEUE_DIR="$PROJECT_ROOT/00_DATA/00_UPLOAD_QUEUE"
prepare_queue_dirs "$QUEUE_DIR"

if ! compgen -G "$QUEUE_DIR/*.csv" >/dev/null && ! compgen -G "$QUEUE_DIR/RACHEL/*.csv" >/dev/null && ! compgen -G "$QUEUE_DIR/Kolibri/*.csv" >/dev/null; then
  log "Queue empty at $QUEUE_DIR"
  exit 0
fi

if flush_all_queues "$QUEUE_DIR"; then
  log "All queued files uploaded."
else
  log "Some queued files failed to upload; see messages above."
  exit 1
fi
