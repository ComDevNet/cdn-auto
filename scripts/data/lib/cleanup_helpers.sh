#!/bin/bash
# Safe cleanup for RACHEL and ModuleGaze log run folders under 00_DATA.

RESERVED_LOG_RUN_NAMES=(
  "00_PROCESSED"
  "00_UPLOAD_QUEUE"
  "00_KOLIBRI_EXPORTS"
  "00_OC4D_ASSESSMENTS"
)

log_cleanup() {
  if declare -F log >/dev/null 2>&1; then
    log "[cleanup] $*"
  else
    echo "[cleanup] $*"
  fi
}

is_log_run_name() {
  local name="${1:?run name required}"

  if [[ "$name" == *"/"* || "$name" == *".."* ]]; then
    return 1
  fi

  local reserved
  for reserved in "${RESERVED_LOG_RUN_NAMES[@]}"; do
    if [[ "$name" == "$reserved" ]]; then
      return 1
    fi
  done

  [[ "$name" =~ ^[A-Za-z0-9_-]+_(modulegaze_)?logs_[0-9]{4}_[0-9]{2}_[0-9]{2}$ ]]
}

_resolve_child_dir() {
  local parent_dir="$1"
  local child_name="$2"

  if ! is_log_run_name "$child_name"; then
    return 1
  fi

  local target
  target="$(CDPATH= cd -- "$parent_dir" >/dev/null 2>&1 && pwd)/$child_name"
  if [[ ! -d "$target" ]]; then
    return 1
  fi

  local resolved_parent
  resolved_parent="$(CDPATH= cd -- "$(dirname -- "$target")" >/dev/null 2>&1 && pwd)"
  local expected_parent
  expected_parent="$(CDPATH= cd -- "$parent_dir" >/dev/null 2>&1 && pwd)"
  if [[ "$resolved_parent" != "$expected_parent" ]]; then
    return 1
  fi

  printf '%s\n' "$target"
}

_remove_dir_if_safe() {
  local target="$1"
  if [[ -z "$target" || ! -d "$target" ]]; then
    return 1
  fi

  rm -rf -- "$target"
}

cleanup_raw_run_folder() {
  local data_dir="${1:?data dir required}"
  local run_name="${2:?run name required}"
  local target

  if ! target="$(_resolve_child_dir "$data_dir" "$run_name")"; then
    log_cleanup "Skipped raw cleanup for invalid or missing run folder: $run_name"
    return 0
  fi

  if _remove_dir_if_safe "$target"; then
    log_cleanup "Removed raw run folder: $run_name"
  else
    log_cleanup "Could not remove raw run folder: $run_name"
  fi
}

cleanup_processed_run_folder() {
  local processed_root="${1:?processed root required}"
  local run_name="${2:?run name required}"
  local target

  if ! target="$(_resolve_child_dir "$processed_root" "$run_name")"; then
    log_cleanup "Skipped processed cleanup for invalid or missing run folder: $run_name"
    return 0
  fi

  if _remove_dir_if_safe "$target"; then
    log_cleanup "Removed processed run folder: $run_name"
  else
    log_cleanup "Could not remove processed run folder: $run_name"
  fi
}

cleanup_processed_for_uploaded_csv() {
  local processed_root="${1:-}"
  local csv_path="${2:?csv path required}"
  local basename run_name parent_dir

  if [[ -z "$processed_root" || ! -d "$processed_root" ]]; then
    return 0
  fi

  basename="$(basename -- "$csv_path")"
  parent_dir="$(find "$processed_root" -maxdepth 2 -type f -name "$basename" -printf '%h\n' 2>/dev/null | head -n1)"
  if [[ -z "$parent_dir" ]]; then
    return 0
  fi

  run_name="$(basename -- "$parent_dir")"
  cleanup_processed_run_folder "$processed_root" "$run_name"
}
