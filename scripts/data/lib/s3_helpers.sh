#!/bin/bash

_helpers_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "$_helpers_dir/cleanup_helpers.sh"

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

prepare_queue_dirs() {
  local queue_root="${1:?queue root required}"
  mkdir -p "$queue_root" "$queue_root/RACHEL" "$queue_root/Kolibri" "$queue_root/ModuleGaze" "$queue_root/OC4DAssessments"
}

queue_one() {
  local file_path="$1"
  local queue_root="${2:?queue root required}"
  local folder_name="${3:-RACHEL}"
  local target_dir

  target_dir="$(queue_dir_for_folder "$queue_root" "$folder_name")"
  mkdir -p "$target_dir"
  cp -f "$file_path" "$target_dir/"
  log "[queue] Queued $(basename "$file_path") for $folder_name uploads."
}

flush_queue_dir() {
  local queue_dir="$1"
  local folder_name="${2:-RACHEL}"
  local failed=0
  local files=()

  shopt -s nullglob
  files=("$queue_dir"/*.csv)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    return 0
  fi

  for queued_file in "${files[@]}"; do
    if upload_one "$queued_file" "$folder_name"; then
      rm -f "$queued_file"
      if [[ -n "${CDN_AUTO_PROCESSED_ROOT:-}" && ("$folder_name" == "RACHEL" || "$folder_name" == "ModuleGaze") ]]; then
        cleanup_processed_for_uploaded_csv "$CDN_AUTO_PROCESSED_ROOT" "$queued_file"
      fi
    else
      log "Leaving queued: $(basename "$queued_file")"
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

  # Backward compatibility for old queue files that were stored at the queue root.
  flush_queue_dir "$queue_root" "RACHEL" || failed=1
  flush_queue_dir "$queue_root/RACHEL" "RACHEL" || failed=1
  flush_queue_dir "$queue_root/Kolibri" "Kolibri" || failed=1
  flush_queue_dir "$queue_root/ModuleGaze" "ModuleGaze" || failed=1

  helpers_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [[ -f "$helpers_dir/oc4d_assessment_helpers.sh" ]]; then
    # shellcheck disable=SC1091
    source "$helpers_dir/oc4d_assessment_helpers.sh"
    flush_oc4d_queue "$queue_root" || failed=1
  fi

  return "$failed"
}
