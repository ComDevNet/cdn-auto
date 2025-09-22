#!/bin/sh
# Flush queue with per-bucket region autodetect; no global AWS config required
set -eu

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)
CONFIG_FILE="$PROJECT_ROOT/config/automation.conf"

load_config() {
  src="$CONFIG_FILE"
  tmp=""
  if [ -r "$src" ]; then . "$src"; log "⚙️  Config loaded (direct): $src"; return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="/tmp/cdn_auto_conf.$$"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then chmod 600 "$tmp"; . "$tmp"; rm -f "$tmp"; log "⚙️  Config loaded (sudo)"; return 0; fi
  fi
  log "❌ Cannot read config: $src"; exit 1
}
load_config

bucket_name() { bn="${S3_BUCKET#s3://}"; echo "${bn%%/*}"; }

bucket_region() {
  b="$(bucket_name)"; reg=""
  reg="$(aws --region us-east-1 s3api get-bucket-location --bucket "$b" --query 'LocationConstraint' --output text 2>/dev/null || true)"
  [ -z "$reg" ] || [ "$reg" = "None" ] && reg="us-east-1"
  [ "$reg" = "EU" ] && reg="eu-west-1"
  if [ -z "$reg" ] && command -v curl >/dev/null 2>&1; then
    reg="$(curl -sI "https://${b}.s3.amazonaws.com/" | tr -d '\r' | awk -F': ' 'BEGIN{IGNORECASE=1}/^x-amz-bucket-region:/{print $2;exit}')"
  fi
  echo "$reg"
}

join_path() { a="${1%/}"; b="${2#/}"; echo "${a}/${b}"; }

upload_one() {
  file_path="$1"
  remote_base="${S3_BUCKET%/}"
  [ -n "${S3_SUBFOLDER:-}" ] && remote_base="$(join_path "$remote_base" "$S3_SUBFOLDER")"
  remote_path="$(join_path "$remote_base" "RACHEL/$(basename "$file_path")")"
  reg="$(bucket_region)"
  log "⬆️  $(basename "$file_path") → $remote_path (region=$reg)"
  if out="$(aws --region "$reg" s3 cp "$file_path" "$remote_path" 2>&1)"; then
    log "✅ OK: $(basename "$file_path")"
    return 0
  else
    log "❌ FAIL: $(basename "$file_path") :: $out"
    return 1
  fi
}

QUEUE_DIR="$PROJECT_ROOT/00_DATA/00_UPLOAD_QUEUE"
set +e; files=$(ls "$QUEUE_DIR"/*.csv 2>/dev/null); rc=$?; set -e
[ $rc -ne 0 ] && { log "Queue empty at $QUEUE_DIR"; exit 0; }

fail=0
for f in $files; do if upload_one "$f"; then rm -f "$f"; else fail=$((fail+1)); fi; done
[ $fail -eq 0 ] && log "All queued files uploaded." || log "$fail file(s) failed; see messages above."
