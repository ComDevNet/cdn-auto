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

kolibri_export_filename() {
  local device_location="${1:-kolibri}"
  local timestamp="${2:-$(date '+%Y_%m_%d_%H%M%S')}"
  echo "${device_location}_kolibri_summary_${timestamp}.csv"
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
