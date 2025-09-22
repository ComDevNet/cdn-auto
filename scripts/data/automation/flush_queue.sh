#!/bin/sh
# Flush queue: fix AWS_PROFILE handling (unset when empty) + sudo-aware config load
set -eu

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)
CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

load_config() {
  src="$CONFIG_FILE"
  tmp=""
  if [ -r "$src" ]; then
    # shellcheck disable=SC1090
    . "$src"
    log "⚙️  Config loaded (direct): $src"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="/tmp/cdn_auto_conf.$$"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp"
      . "$tmp"
      rm -f "$tmp"
      log "⚙️  Config loaded (sudo): $src"
      return 0
    fi
  fi
  log "❌ Cannot read config: $src"; exit 1
}
load_config

# Normalize AWS env
if [ -n "${AWS_PROFILE:-}" ]; then
  export AWS_PROFILE
else
  unset AWS_PROFILE || true
fi
if [ -n "${AWS_REGION:-}" ]; then
  export AWS_DEFAULT_REGION="$AWS_REGION"
elif [ -n "${AWS_DEFAULT_REGION:-}" ]; then
  export AWS_DEFAULT_REGION
else
  unset AWS_DEFAULT_REGION || true
fi

DATA_DIR="$PROJECT_ROOT/00_DATA"
QUEUE_DIR="$DATA_DIR/00_UPLOAD_QUEUE"

join_path() { a="${1%/}"; b="${2#/}"; echo "${a}/${b}"; }

upload_one() {
  file_path="$1"
  remote_base="${S3_BUCKET%/}"
  [ -n "${S3_SUBFOLDER:-}" ] && remote_base="$(join_path "$remote_base" "$S3_SUBFOLDER")"
  remote_path="$(join_path "$remote_base" "RACHEL/$(basename "$file_path")")"
  log "⬆️  $(basename "$file_path") → $remote_path"
  if out="$(aws s3 cp "$file_path" "$remote_path" 2>&1)"; then
    log "✅ OK: $(basename "$file_path")"
    return 0
  else
    log "❌ FAIL: $(basename "$file_path") :: $out"
    return 1
  fi
}

# Flush
set +e
files=$(ls "$QUEUE_DIR"/*.csv 2>/dev/null)
rc=$?
set -e
if [ $rc -ne 0 ]; then log "Queue empty at $QUEUE_DIR"; exit 0; fi

fail=0
for f in $files; do
  if upload_one "$f"; then rm -f "$f"; else fail=$((fail+1)); fi
done

if [ $fail -eq 0 ]; then log "All queued files uploaded."; else log "$fail file(s) failed; see messages above."; fi
