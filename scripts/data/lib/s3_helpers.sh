#!/bin/bash

_helpers_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "$_helpers_dir/cleanup_helpers.sh"

QUEUE_STAGES=(RACHEL ModuleGaze OC4DAssessments)
QUEUE_STATES=(pending uploading completed failed)
# ponytail: keep completed for a week; bump QUEUE_COMPLETED_RETENTION_DAYS if audits need longer
QUEUE_COMPLETED_RETENTION_DAYS="${QUEUE_COMPLETED_RETENTION_DAYS:-7}"

join_path() {
  local a="${1%/}"
  local b="${2#/}"
  echo "${a}/${b}"
}

bucket_name() {
  local bucket="${S3_BUCKET#s3://}"
  echo "${bucket%%/*}"
}

bucket_region() {
  local bucket
  local region=""

  bucket="$(bucket_name)"
  region="$(aws --region us-east-1 s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text 2>/dev/null || true)"

  if [[ -z "$region" || "$region" == "None" ]]; then
    region="us-east-1"
  fi
  if [[ "$region" == "EU" ]]; then
    region="eu-west-1"
  fi

  if [[ -z "$region" ]] && command -v curl >/dev/null 2>&1; then
    region="$(curl -sI "https://${bucket}.s3.amazonaws.com/" | tr -d '\r' | awk -F': ' 'BEGIN{IGNORECASE=1}/^x-amz-bucket-region:/{print $2; exit}')"
  fi

  echo "$region"
}

aws_cp_region() {
  local file_path="$1"
  local destination="$2"
  local region

  region="$(bucket_region)"
  aws --region "$region" s3 cp "$file_path" "$destination"
}

remote_base_path() {
  local base="${S3_BUCKET%/}"
  if [[ -n "${S3_SUBFOLDER:-}" ]]; then
    base="$(join_path "$base" "$S3_SUBFOLDER")"
  fi
  echo "$base"
}

upload_one() {
  local file_path="$1"
  local folder_name="${2:-RACHEL}"
  local remote_base
  local remote_path
  local output
  local rc

  remote_base="$(remote_base_path)"
  if [[ "$folder_name" == "RACHEL" && -n "${RACHEL_SUBFOLDER:-}" ]]; then
    remote_path="$(join_path "$remote_base" "$folder_name/${RACHEL_SUBFOLDER}/$(basename "$file_path")")"
  else
    remote_path="$(join_path "$remote_base" "$folder_name/$(basename "$file_path")")"
  fi

  log "[upload] $(basename "$file_path") -> $remote_path"
  output="$(aws_cp_region "$file_path" "$remote_path" 2>&1)"
  rc=$?

  if (( rc == 0 )); then
    log "[done] Uploaded: $(basename "$file_path")"
    return 0
  fi

  log "[error] Upload failed for $(basename "$file_path"): $output"
  return 1
}

queue_dir_for_folder() {
  local queue_root="${1:?queue root required}"
  local folder_name="${2:-RACHEL}"
  echo "$queue_root/$folder_name"
}

queue_state_dir() {
  local queue_root="${1:?queue root required}"
  local folder_name="${2:-RACHEL}"
  local state="${3:-pending}"
  echo "$queue_root/$folder_name/$state"
}

queue_marker_path() {
  local queue_root="${1:?queue root required}"
  local name="${2:?marker name required}"
  echo "$queue_root/.$name"
}

write_queue_marker() {
  local queue_root="${1:?queue root required}"
  local name="${2:?marker name required}"
  local value="${3:-$(date -Iseconds)}"
  local path tmp
  path="$(queue_marker_path "$queue_root" "$name")"
  tmp="${path}.tmp.$$"
  printf '%s\n' "$value" > "$tmp"
  mv -f "$tmp" "$path"
}

read_queue_marker() {
  local queue_root="${1:?queue root required}"
  local name="${2:?marker name required}"
  local path
  path="$(queue_marker_path "$queue_root" "$name")"
  [[ -f "$path" ]] || return 1
  tr -d '\r\n' < "$path"
}

# Move payload + known sidecars between state dirs (atomic rename per file).
_queue_move_item() {
  local src_file="$1"
  local dest_dir="$2"
  local base dest src_dir name

  [[ -f "$src_file" ]] || return 1
  mkdir -p "$dest_dir"
  base="$(basename "$src_file")"
  src_dir="$(dirname -- "$src_file")"
  dest="$dest_dir/$base"
  mv -f "$src_file" "$dest"
  for name in "${base}.cdnrun" "${base}.oc4dkey"; do
    [[ -f "$src_dir/$name" ]] || continue
    mv -f "$src_dir/$name" "$dest_dir/$name"
  done
  printf '%s\n' "$dest"
}

_migrate_legacy_queue_files() {
  local queue_root="${1:?queue root required}"
  local stage pending_dir file
  local helpers_dir

  helpers_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [[ -f "$helpers_dir/oc4d_assessment_helpers.sh" ]]; then
    # shellcheck disable=SC1091
    source "$helpers_dir/oc4d_assessment_helpers.sh"
  fi

  # Legacy root-level CSVs → RACHEL/pending
  pending_dir="$(queue_state_dir "$queue_root" "RACHEL" "pending")"
  mkdir -p "$pending_dir"
  shopt -s nullglob
  for file in "$queue_root"/*.csv; do
    _queue_move_item "$file" "$pending_dir" >/dev/null || true
  done
  shopt -u nullglob

  for stage in "${QUEUE_STAGES[@]}"; do
    pending_dir="$(queue_state_dir "$queue_root" "$stage" "pending")"
    mkdir -p "$pending_dir"
    shopt -s nullglob
    for file in "$queue_root/$stage"/*.csv "$queue_root/$stage"/*.json; do
      [[ -f "$file" ]] || continue
      _queue_move_item "$file" "$pending_dir" >/dev/null || true
    done
    shopt -u nullglob
  done
}

# Crash recovery: anything left in uploading/ returns to pending/.
_recover_uploading_queue() {
  local queue_root="${1:?queue root required}"
  local stage uploading_dir pending_dir file

  for stage in "${QUEUE_STAGES[@]}"; do
    uploading_dir="$(queue_state_dir "$queue_root" "$stage" "uploading")"
    pending_dir="$(queue_state_dir "$queue_root" "$stage" "pending")"
    mkdir -p "$uploading_dir" "$pending_dir"
    shopt -s nullglob
    for file in "$uploading_dir"/*.csv "$uploading_dir"/*.json; do
      [[ -f "$file" ]] || continue
      log "[queue] Recovering interrupted upload: $(basename "$file") → pending"
      _queue_move_item "$file" "$pending_dir" >/dev/null || true
    done
    shopt -u nullglob
  done
}

purge_completed_queue() {
  local queue_root="${1:?queue root required}"
  local days="${2:-$QUEUE_COMPLETED_RETENTION_DAYS}"
  local stage completed_dir

  for stage in "${QUEUE_STAGES[@]}"; do
    completed_dir="$(queue_state_dir "$queue_root" "$stage" "completed")"
    [[ -d "$completed_dir" ]] || continue
    find "$completed_dir" -type f \( -name '*.csv' -o -name '*.json' -o -name '*.cdnrun' -o -name '*.oc4dkey' \) \
      -mtime "+$days" -delete 2>/dev/null || true
  done
}

prepare_queue_dirs() {
  local queue_root="${1:?queue root required}"
  local stage state

  mkdir -p "$queue_root"
  for stage in "${QUEUE_STAGES[@]}"; do
    for state in "${QUEUE_STATES[@]}"; do
      mkdir -p "$queue_root/$stage/$state"
    done
  done
  _migrate_legacy_queue_files "$queue_root"
  _recover_uploading_queue "$queue_root"
}

# True if basename already enqueued (pending/uploading) or completed.
queue_item_exists() {
  local queue_root="${1:?queue root required}"
  local folder_name="${2:-RACHEL}"
  local base="${3:?basename required}"
  local state dir

  for state in pending uploading completed; do
    dir="$(queue_state_dir "$queue_root" "$folder_name" "$state")"
    [[ -f "$dir/$base" ]] && return 0
  done
  return 1
}

count_queue_state() {
  local queue_root="${1:?queue root required}"
  local folder_name="${2:-RACHEL}"
  local state="${3:-pending}"
  local dir count=0
  dir="$(queue_state_dir "$queue_root" "$folder_name" "$state")"
  [[ -d "$dir" ]] || { echo 0; return 0; }
  shopt -s nullglob
  local files=("$dir"/*.csv "$dir"/*.json)
  shopt -u nullglob
  count=${#files[@]}
  echo "$count"
}

queue_one() {
  local file_path="$1"
  local queue_root="${2:?queue root required}"
  local folder_name="${3:-RACHEL}"
  local run_name="${4:-}"
  local pending_dir base tmp dest

  prepare_queue_dirs "$queue_root"
  pending_dir="$(queue_state_dir "$queue_root" "$folder_name" "pending")"
  base="$(basename "$file_path")"
  dest="$pending_dir/$base"

  if [[ -f "$(queue_state_dir "$queue_root" "$folder_name" "completed")/$base" ]]; then
    log "[queue] Skip $base for $folder_name (already completed)."
    return 0
  fi
  if [[ -f "$(queue_state_dir "$queue_root" "$folder_name" "uploading")/$base" ]]; then
    log "[queue] Skip $base for $folder_name (upload in progress)."
    return 0
  fi

  # Atomic replace of pending (and clear failed twin).
  rm -f "$(queue_state_dir "$queue_root" "$folder_name" "failed")/$base" \
    "$(queue_run_sidecar_for "$(queue_state_dir "$queue_root" "$folder_name" "failed")/$base")"
  tmp="$pending_dir/.${base}.tmp.$$"
  cp -f "$file_path" "$tmp"
  mv -f "$tmp" "$dest"
  if [[ -n "$run_name" && ("$folder_name" == "RACHEL" || "$folder_name" == "ModuleGaze") ]]; then
    write_queue_run_sidecar "$dest" "$run_name"
  fi
  log "[queue] Queued $base for $folder_name (pending)."
}

# UPLOAD_WINDOW: always | HH:MM-HH:MM (overnight OK) | empty → always
# FORCE_UPLOAD=1 bypasses the window (flush_queue.sh).
upload_window_open() {
  local window="${UPLOAD_WINDOW:-always}"
  local now_hm start_hm end_hm now_min start_min end_min

  [[ "${FORCE_UPLOAD:-0}" == "1" ]] && return 0
  window="${window,,}"
  [[ -z "$window" || "$window" == "always" ]] && return 0

  if [[ ! "$window" =~ ^([0-2][0-9]:[0-5][0-9])-([0-2][0-9]:[0-5][0-9])$ ]]; then
    log "[warn] Invalid UPLOAD_WINDOW='$UPLOAD_WINDOW'; treating as always open."
    return 0
  fi

  start_hm="${BASH_REMATCH[1]}"
  end_hm="${BASH_REMATCH[2]}"
  now_hm="$(date '+%H:%M')"
  now_min=$((10#${now_hm%:*} * 60 + 10#${now_hm#*:}))
  start_min=$((10#${start_hm%:*} * 60 + 10#${start_hm#*:}))
  end_min=$((10#${end_hm%:*} * 60 + 10#${end_hm#*:}))

  if (( start_min == end_min )); then
    return 0
  fi
  if (( start_min < end_min )); then
    (( now_min >= start_min && now_min < end_min ))
  else
    # Overnight, e.g. 22:00-06:00
    (( now_min >= start_min || now_min < end_min ))
  fi
}

next_upload_window_hint() {
  local window="${UPLOAD_WINDOW:-always}"
  window="${window,,}"
  if [[ -z "$window" || "$window" == "always" ]]; then
    echo "always (dispatcher may upload whenever online)"
    return 0
  fi
  if upload_window_open; then
    echo "open now ($UPLOAD_WINDOW)"
  else
    echo "closed; opens at ${window%%-*} (window $UPLOAD_WINDOW)"
  fi
}

flush_queue_dir() {
  local queue_dir="$1"
  local folder_name="${2:-RACHEL}"
  local failed=0
  local files=()
  local queued_file uploading_dir completed_dir failed_dir active

  # Accept either a state dir (.../pending) or legacy stage dir.
  if [[ "$(basename "$queue_dir")" == "pending" ]]; then
    uploading_dir="$(dirname "$queue_dir")/uploading"
    completed_dir="$(dirname "$queue_dir")/completed"
    failed_dir="$(dirname "$queue_dir")/failed"
  else
    uploading_dir="$queue_dir/uploading"
    completed_dir="$queue_dir/completed"
    failed_dir="$queue_dir/failed"
    queue_dir="$queue_dir/pending"
  fi
  mkdir -p "$queue_dir" "$uploading_dir" "$completed_dir" "$failed_dir"

  shopt -s nullglob
  files=("$queue_dir"/*.csv)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    return 0
  fi

  for queued_file in "${files[@]}"; do
    active="$(_queue_move_item "$queued_file" "$uploading_dir")" || {
      failed=1
      continue
    }
    if upload_one "$active" "$folder_name"; then
      if [[ -n "${CDN_AUTO_PROCESSED_ROOT:-}" && ("$folder_name" == "RACHEL" || "$folder_name" == "ModuleGaze") ]]; then
        cleanup_processed_for_uploaded_csv "$CDN_AUTO_PROCESSED_ROOT" "$active"
      fi
      _queue_move_item "$active" "$completed_dir" >/dev/null || rm -f "$active"
    else
      log "Leaving pending: $(basename "$active")"
      _queue_move_item "$active" "$queue_dir" >/dev/null || true
      failed=1
    fi
  done

  return "$failed"
}

flush_all_queues() {
  local queue_root="${1:?queue root required}"
  local failed=0
  local helpers_dir

  prepare_queue_dirs "$queue_root"
  purge_completed_queue "$queue_root"

  if ! upload_window_open; then
    log "[upload] Window closed ($(next_upload_window_hint)); leaving pending items queued."
    return 0
  fi

  flush_queue_dir "$(queue_state_dir "$queue_root" "RACHEL" "pending")" "RACHEL" || failed=1
  flush_queue_dir "$(queue_state_dir "$queue_root" "ModuleGaze" "pending")" "ModuleGaze" || failed=1

  helpers_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [[ -f "$helpers_dir/oc4d_assessment_helpers.sh" ]]; then
    # shellcheck disable=SC1091
    source "$helpers_dir/oc4d_assessment_helpers.sh"
    flush_oc4d_queue "$queue_root" || failed=1
  fi

  if (( failed == 0 )); then
    write_queue_marker "$queue_root" "last_upload_ok"
  fi
  return "$failed"
}
