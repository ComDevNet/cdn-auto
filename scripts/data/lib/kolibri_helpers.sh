#!/bin/bash

kolibri_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  fi
}

kolibri_is_available() {
  command -v kolibri >/dev/null 2>&1
}

kolibri_resolve_facility_id() {
  local requested="${1:-${KOLIBRI_FACILITY_ID:-}}"
  local resolved=""

  if [[ -n "$requested" ]]; then
    echo "$requested"
    return 0
  fi

  if ! kolibri_is_available; then
    return 1
  fi

  resolved="$(kolibri manage shell -c "from kolibri.core.auth.models import Facility; facility = Facility.get_default_facility(); print(getattr(facility, 'id', ''))" 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [[ -z "$resolved" || "$resolved" == "None" ]]; then
    return 1
  fi

  echo "$resolved"
}

kolibri_schedule_window() {
  local schedule_type="$1"
  local device_location="$2"
  local run_interval="${3:-}"

  if [[ -z "${PROJECT_ROOT:-}" ]]; then
    kolibri_log "[error] PROJECT_ROOT is not set; cannot resolve Kolibri time window."
    return 1
  fi

  if [[ -n "$run_interval" ]]; then
    python3 "$PROJECT_ROOT/scripts/data/automation/time_window.py" "$schedule_type" "$device_location" "kolibri_summary" "$run_interval"
  else
    python3 "$PROJECT_ROOT/scripts/data/automation/time_window.py" "$schedule_type" "$device_location" "kolibri_summary"
  fi
}

kolibri_is_valid_date() {
  local candidate="$1"
  date -d "$candidate" '+%Y-%m-%d' >/dev/null 2>&1
}

kolibri_manual_range_filename() {
  local device_location="$1"
  local start_date="$2"
  local end_date="$3"

  local file_stamp=""
  local month_start=""
  local month_end=""
  local year_start=""
  local year_end=""
  local expected_week_end=""

  if [[ "$start_date" == "$end_date" ]]; then
    file_stamp="$(date -d "$start_date" '+%d_%m_%Y')"
    echo "${device_location}_${file_stamp}_kolibri_summary.csv"
    return 0
  fi

  month_start="$(date -d "$start_date" '+%Y-%m-01')"
  month_end="$(date -d "$month_start +1 month -1 day" '+%Y-%m-%d')"
  if [[ "$start_date" == "$month_start" && "$end_date" == "$month_end" ]]; then
    file_stamp="$(date -d "$start_date" '+%m_%Y')"
    echo "${device_location}_${file_stamp}_kolibri_summary.csv"
    return 0
  fi

  year_start="$(date -d "$start_date" '+%Y-01-01')"
  year_end="$(date -d "$year_start +1 year -1 day" '+%Y-%m-%d')"
  if [[ "$start_date" == "$year_start" && "$end_date" == "$year_end" ]]; then
    file_stamp="$(date -d "$start_date" '+%Y')"
    echo "${device_location}_${file_stamp}_kolibri_summary.csv"
    return 0
  fi

  expected_week_end="$(date -d "$start_date +6 day" '+%Y-%m-%d')"
  if [[ "$(date -d "$start_date" '+%u')" == "1" && "$(date -d "$end_date" '+%u')" == "7" && "$end_date" == "$expected_week_end" ]]; then
    file_stamp="$(date -d "$start_date" '+%W_%m_%Y')"
    echo "${device_location}_${file_stamp}_kolibri_summary.csv"
    return 0
  fi

  local start_stamp="${start_date//-/}"
  local end_stamp="${end_date//-/}"
  echo "${device_location}_${start_stamp}_to_${end_stamp}_kolibri_summary.csv"
}

kolibri_export_summary() {
  local output_file="$1"
  local facility_id="${2:-}"
  local start_date="${3:-1970-01-01T00:00:00}"
  local end_date="${4:-$(date '+%Y-%m-%dT%H:%M:%S')}"
  local args=()

  if [[ -z "$facility_id" ]]; then
    facility_id="$(kolibri_resolve_facility_id || true)"
  fi

  args=(manage exportlogs -l summary --start_date "$start_date" --end_date "$end_date" -O "$output_file" -w)
  if [[ -n "$facility_id" ]]; then
    args+=(--facility "$facility_id")
    kolibri_log "[kolibri] Exporting summary for facility $facility_id"
  else
    kolibri_log "[kolibri] Exporting summary for Kolibri's default facility"
  fi

  kolibri_log "[kolibri] Export window: $start_date to $end_date"
  kolibri "${args[@]}"
}

kolibri_has_data_rows() {
  local output_file="$1"
  local line_count=0

  if [[ ! -f "$output_file" ]]; then
    return 1
  fi

  line_count="$(wc -l < "$output_file" 2>/dev/null || echo 0)"
  [[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0
  (( line_count > 1 ))
}
