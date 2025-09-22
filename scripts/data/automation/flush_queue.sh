#!/bin/bash
# sudo-aware flush queue
set -euo pipefail
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

load_config() {
  local src="$CONFIG_FILE" tmp=""
  if [[ -r "$src" ]]; then source "$src"; log "⚙️  Config loaded (direct): $src"; return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="/tmp/cdn_auto_conf.$$.sh"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp"; source "$tmp"; rm -f "$tmp"; log "⚙️  Config loaded (sudo)"; return 0
    fi
  fi
  log "❌ Cannot read config: $src"; exit 1
}
load_config

export AWS_PROFILE="${AWS_PROFILE:-}"
export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

DATA_DIR="$PROJECT_ROOT/00_DATA"
QUEUE_DIR="$DATA_DIR/00_UPLOAD_QUEUE"
join_path() { local a="${1%/}" b="${2#/}"; echo "${a}/${b}"; }

upload_one() {
  local file_path="$1"
  local remote_base="${S3_BUCKET%/}"
  [[ -n "${S3_SUBFOLDER:-}" ]] && remote_base="$(join_path "$remote_base" "$S3_SUBFOLDER")"
  local remote_path="$(join_path "$remote_base" "RACHEL/$(basename "$file_path")")"
  log "⬆️  $(basename "$file_path") → $remote_path"
  local out rc; out="$(aws s3 cp "$file_path" "$remote_path" 2>&1)"; rc=$?
  if (( rc == 0 )); then log "✅ OK: $(basename "$file_path")"; return 0
  else log "❌ FAIL: $(basename "$file_path") :: $out"; return 1; fi
}

shopt -s nullglob
files=( "$QUEUE_DIR"/*.csv )
shopt -u nullglob
if (( ${#files[@]} == 0 )); then log "Queue empty at $QUEUE_DIR"; exit 0; fi
log "Found ${#files[@]} queued file(s) in $QUEUE_DIR"
fail=0
for f in "${files[@]}"; do if upload_one "$f"; then rm -f "$f"; else fail=$((fail+1)); fi; done
if (( fail == 0 )); then log "All queued files uploaded."; else log "$fail file(s) failed; see messages above."; fi
