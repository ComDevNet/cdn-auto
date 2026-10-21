#!/bin/bash

background_memory_ready() {
  local available memfile="${CDN_AUTO_MEMINFO_FILE:-/proc/meminfo}"
  available="$(awk '/^MemAvailable:/ {print $2}' "$memfile" 2>/dev/null || true)"
  if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < 786432 )); then
    log "[memory] Background work deferred until at least 768MiB is available; data stays queued."
    return 1
  fi
}

harvest_storage_ready() {
  background_memory_ready || return 1
  local data_dir="$1" queue_root="$2"
  local min_kb="${CDN_AUTO_MIN_FREE_KB:-5242880}"
  local resume_kb="${CDN_AUTO_RESUME_FREE_KB:-8388608}"
  local available used marker
  marker="$queue_root/.harvest_storage_paused"
  read -r available used < <(df -Pk "$data_dir" | awk 'NR==2 {gsub(/%/, "", $5); print $4, $5}')
  if [[ ! "$available" =~ ^[0-9]+$ || ! "$used" =~ ^[0-9]+$ ]]; then
    log "[storage] Cannot measure free space; preserving sources and skipping collection."
    return 1
  fi
  if (( available < min_kb || used >= 90 )); then
    printf '%s free_kb=%s used_percent=%s\n' "$(date -Iseconds)" "$available" "$used" > "$marker"
    log "[storage] Collection paused: free=${available}KB, used=${used}%. Pending uploads and source data are retained."
    return 1
  fi
  if [[ -f "$marker" ]]; then
    if (( available < resume_kb || used > 85 )); then
      log "[storage] Waiting for recovery: need ${resume_kb}KB free and <=85% used."
      return 1
    fi
    rm -f -- "$marker"
    log "[storage] Free space recovered; collection resumed."
  fi
  return 0
}

background_aws_upload() {
  local file_path="$1" destination="$2" region="$3" bytes budget
  bytes="$(wc -c < "$file_path")"
  # Allow large files time to finish at the background bandwidth limit.
  budget="${CDN_AUTO_UPLOAD_TIMEOUT_SECONDS:-$((120 + bytes / 524288))}"
  timeout --signal=TERM --kill-after=10s "${budget}s" \
    env AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=3 AWS_PAGER= \
    aws --cli-connect-timeout 10 --cli-read-timeout 30 --region "$region" \
    s3 cp --no-progress --only-show-errors "$file_path" "$destination"
}
