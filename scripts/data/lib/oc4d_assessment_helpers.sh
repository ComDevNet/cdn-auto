#!/bin/bash
# OC4D assessment pull helpers: key builder, validation, API fetch, upload/queue routing.

if ! declare -f log >/dev/null 2>&1; then
  log() { echo "[oc4d] $*"; }
fi

# Bump when completed marking schemes must be delivered again. The version is
# stored on line 3 of the queue sidecar so old completed files are refreshed
# once without repeatedly uploading unchanged schemes on every run.
OC4D_SCHEME_DELIVERY_VERSION="${OC4D_SCHEME_DELIVERY_VERSION:-2}"

oc4d_sanitize_key_segment() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  value="${value#/}"
  value="${value%/}"
  printf '%s' "$value"
}

oc4d_bucket_name() {
  local bucket="${OC4D_BUCKET:-oc4d-raw-reports}"
  bucket="${bucket#s3://}"
  bucket="${bucket%%/*}"
  printf '%s' "$bucket"
}

oc4d_bucket_region() {
  local bucket region=""
  bucket="$(oc4d_bucket_name)"
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
  printf '%s' "$region"
}

oc4d_aws_cp() {
  local file_path="$1"
  local destination="$2"
  local region
  region="$(oc4d_bucket_region)"
  aws --region "$region" s3 cp "$file_path" "$destination"
}

oc4d_safe_filename_base() {
  local value="${1:-assessment-result}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g')"
  [[ -n "$value" ]] || value="assessment-result"
  printf '%s' "$value"
}

oc4d_iso_ts_for_key() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    value="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi
  printf '%s' "$value" | tr ':' '-' | tr -d '\r\n'
}

# build_oc4d_assessment_key parentOrg studentId assessmentId base isoTs
build_oc4d_assessment_key() {
  local parent_org student_id assessment_id base iso_ts
  parent_org="$(oc4d_sanitize_key_segment "$1")"
  student_id="$(oc4d_sanitize_key_segment "$2")"
  assessment_id="$(oc4d_sanitize_key_segment "$3")"
  base="$(oc4d_safe_filename_base "$4")"
  iso_ts="$(oc4d_iso_ts_for_key "$5")"

  if [[ -z "$parent_org" || -z "$student_id" || -z "$assessment_id" || -z "$base" || -z "$iso_ts" ]]; then
    return 1
  fi

  printf '%s/Assessments/%s/%s/%s__%s.csv' \
    "$parent_org" "$student_id" "$assessment_id" "$base" "$iso_ts"
}

validate_oc4d_assessment_key() {
  local key="$1"
  if [[ -z "$key" ]]; then
    echo "missing object key"
    return 1
  fi
  if [[ "$key" != */Assessments/*/*/*__*.csv ]]; then
    echo "key must match {parentOrg}/Assessments/{studentId}/{assessmentId}/{base}__{isoTs}.csv"
    return 1
  fi
  return 0
}

validate_oc4d_marking_scheme_key() {
  local key="$1"
  if [[ -z "$key" ]]; then
    echo "missing object key"
    return 1
  fi
  if [[ "$key" == */MarkingSchemes/*/*.csv || "$key" == */MarkingSchemes/*/*.json ]]; then
    return 0
  fi
  echo "key must match {parentOrg}/MarkingSchemes/{assessmentId}/{filename}.csv or .json"
  return 1
}

validate_oc4d_upload_key() {
  local key="$1"
  if validate_oc4d_assessment_key "$key" 2>/dev/null; then
    return 0
  fi
  if validate_oc4d_marking_scheme_key "$key" 2>/dev/null; then
    return 0
  fi
  echo "key must match an OC4D assessment result or marking scheme path"
  return 1
}

oc4d_assessments_enabled() {
  [[ "${OC4D_ASSESSMENTS_ENABLED:-0}" == "1" || "${OC4D_ASSESSMENTS_ENABLED:-false}" == "true" ]]
}

oc4d_queue_dir() {
  local queue_root="${1:?queue root required}"
  local state="${2:-pending}"
  if declare -F queue_state_dir >/dev/null 2>&1; then
    queue_state_dir "$queue_root" "OC4DAssessments" "$state"
  else
    printf '%s/OC4DAssessments/%s' "$queue_root" "$state"
  fi
}

oc4d_sidecar_for_csv() {
  printf '%s.oc4dkey' "$1"
}

# Persist result_id only after a successful S3 upload (never at enqueue).
record_oc4d_uploaded_id() {
  local result_id="${1:-}"
  local state_file="${OC4D_STATE_FILE:-}"
  [[ -n "$result_id" && -n "$state_file" ]] || return 0
  python3 - "$state_file" "$result_id" <<'PY'
import json
import sys
from pathlib import Path

FORMAT_VERSION = 2
state_path = Path(sys.argv[1])
rid = sys.argv[2].strip()
if not rid:
    raise SystemExit(0)
uploaded = set()
if state_path.exists():
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
        uploaded = set(payload.get("uploadedIds", []))
    except json.JSONDecodeError:
        uploaded = set()
uploaded.add(rid)
state_path.parent.mkdir(parents=True, exist_ok=True)
tmp = state_path.with_suffix(".tmp")
tmp.write_text(
    json.dumps(
        {"formatVersion": FORMAT_VERSION, "uploadedIds": sorted(uploaded)},
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
tmp.replace(state_path)
PY
}

upload_oc4d_one() {
  local file_path="$1"
  local s3_key="$2"
  local bucket remote_path output rc reason

  reason="$(validate_oc4d_upload_key "$s3_key")" || {
    log "[oc4d][error] Invalid key for $(basename "$file_path"): $reason"
    return 1
  }

  bucket="$(oc4d_bucket_name)"
  remote_path="s3://${bucket}/${s3_key}"
  log "[oc4d][upload] $(basename "$file_path") -> $remote_path"
  output="$(oc4d_aws_cp "$file_path" "$remote_path" 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    log "[oc4d][done] Uploaded: $(basename "$file_path")"
    return 0
  fi
  log "[oc4d][error] Upload failed for $(basename "$file_path"): $output"
  return 1
}

queue_oc4d_one() {
  local file_path="$1"
  local queue_root="${2:?queue root required}"
  local s3_key="$3"
  local result_id="${4:-}"
  local target_dir base sidecar tmp dest completed_dir uploading_dir
  local existing existing_key existing_version required_version=""

  if declare -F prepare_queue_dirs >/dev/null 2>&1; then
    prepare_queue_dirs "$queue_root"
  fi
  target_dir="$(oc4d_queue_dir "$queue_root" "pending")"
  mkdir -p "$target_dir"
  base="$(basename "$file_path")"
  dest="$target_dir/$base"
  completed_dir="$(oc4d_queue_dir "$queue_root" "completed")"
  uploading_dir="$(oc4d_queue_dir "$queue_root" "uploading")"

  if [[ "$s3_key" == */MarkingSchemes/* ]]; then
    required_version="$OC4D_SCHEME_DELIVERY_VERSION"
  fi

  # Skip only when the completed/uploading payload, key, and delivery version
  # are all current. A stable filename must not permanently hide richer scheme
  # content produced by a later harvest.
  for existing in "$uploading_dir/$base" "$completed_dir/$base"; do
    [[ -f "$existing" ]] || continue
    sidecar="$(oc4d_sidecar_for_csv "$existing")"
    existing_key="$(tr -d '\r' < "$sidecar" 2>/dev/null | sed -n '1p' || true)"
    existing_version="$(tr -d '\r' < "$sidecar" 2>/dev/null | sed -n '3p' || true)"
    if cmp -s "$file_path" "$existing" && [[ "$existing_key" == "$s3_key" ]] &&
      { [[ -z "$required_version" ]] || [[ "$existing_version" == "$required_version" ]]; }; then
      log "[oc4d][queue] Skip $base (identical payload already completed/uploading)."
      return 0
    fi
  done

  # Same payload and S3 key already pending → skip (dedup across harvest reruns).
  if [[ -f "$dest" ]]; then
    existing_key="$(tr -d '\r' < "$(oc4d_sidecar_for_csv "$dest")" 2>/dev/null | sed -n '1p' || true)"
    existing_version="$(tr -d '\r' < "$(oc4d_sidecar_for_csv "$dest")" 2>/dev/null | sed -n '3p' || true)"
    if cmp -s "$file_path" "$dest" && [[ "$existing_key" == "$s3_key" ]] &&
      { [[ -z "$required_version" ]] || [[ "$existing_version" == "$required_version" ]]; }; then
      # Refresh result_id on existing pending sidecars (needed after state-on-success change).
      if [[ -n "$result_id" ]]; then
        sidecar="$(oc4d_sidecar_for_csv "$dest")"
        {
          printf '%s\n' "$s3_key"
          printf '%s\n' "$result_id"
          [[ -n "$required_version" ]] && printf '%s\n' "$required_version"
        } > "${sidecar}.tmp.$$"
        mv -f "${sidecar}.tmp.$$" "$sidecar"
      fi
      log "[oc4d][queue] Skip $base (identical key already pending)."
      return 0
    fi
  fi

  tmp="$target_dir/.${base}.tmp.$$"
  cp -f "$file_path" "$tmp"
  mv -f "$tmp" "$dest"
  sidecar="$(oc4d_sidecar_for_csv "$dest")"
  # Line 1 = S3 key, line 2 = optional assessment result_id (recorded after upload success).
  {
    printf '%s\n' "$s3_key"
    [[ -n "$result_id" ]] && printf '%s\n' "$result_id"
    if [[ -n "$required_version" ]]; then
      [[ -n "$result_id" ]] || printf '\n'
      printf '%s\n' "$required_version"
    fi
  } > "${sidecar}.tmp.$$"
  mv -f "${sidecar}.tmp.$$" "$sidecar"

  log "[oc4d][queue] Queued $base (pending, key=$s3_key)"
}

flush_oc4d_queue() {
  local queue_root="${1:?queue root required}"
  local queue_dir uploading_dir completed_dir failed=0 file active sidecar s3_key result_id files=()

  queue_dir="$(oc4d_queue_dir "$queue_root" "pending")"
  uploading_dir="$(oc4d_queue_dir "$queue_root" "uploading")"
  completed_dir="$(oc4d_queue_dir "$queue_root" "completed")"
  mkdir -p "$queue_dir" "$uploading_dir" "$completed_dir"
  [[ -d "$queue_dir" ]] || return 0

  shopt -s nullglob
  # Marking schemes may be queued as .csv or .json with a matching .oc4dkey sidecar.
  # Rich metadata must be present before its CSV triggers scheme ingestion.
  # The cloud handler also reprocesses on metadata arrival, making this robust
  # if external delivery ever reverses the order.
  files=("$queue_dir"/*.json "$queue_dir"/*.csv)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    return 0
  fi

  for file in "${files[@]}"; do
    sidecar="$(oc4d_sidecar_for_csv "$file")"
    if [[ ! -f "$sidecar" ]]; then
      log "[oc4d][warn] Missing sidecar for queued file $(basename "$file"); leaving in queue."
      failed=1
      continue
    fi
    if declare -F _queue_move_item >/dev/null 2>&1; then
      active="$(_queue_move_item "$file" "$uploading_dir")" || {
        failed=1
        continue
      }
    else
      active="$file"
    fi
    sidecar="$(oc4d_sidecar_for_csv "$active")"
    s3_key="$(tr -d '\r' < "$sidecar" | sed -n '1p')"
    result_id="$(tr -d '\r' < "$sidecar" | sed -n '2p')"
    if upload_oc4d_one "$active" "$s3_key"; then
      record_oc4d_uploaded_id "$result_id"
      if declare -F _queue_move_item >/dev/null 2>&1; then
        _queue_move_item "$active" "$completed_dir" >/dev/null || rm -f "$active" "$sidecar"
      else
        rm -f "$active" "$sidecar"
      fi
    else
      log "[oc4d] Leaving pending: $(basename "$active")"
      if declare -F _queue_move_item >/dev/null 2>&1; then
        _queue_move_item "$active" "$queue_dir" >/dev/null || true
      fi
      failed=1
    fi
  done

  return "$failed"
}

resolve_oc4d_api_token() {
  local api_base="${OC4D_API_BASE_URL:-http://127.0.0.1:3000}"
  local token="${OC4D_API_TOKEN:-}"
  local identifier="${OC4D_API_IDENTIFIER:-admin@comdevnet.com}"
  local password="${OC4D_API_PASSWORD:-}"
  local creds_file="${OC4D_API_CREDENTIALS_FILE:-}"
  local response

  if [[ -n "$token" ]]; then
    printf '%s' "$token"
    return 0
  fi

  if [[ -n "$creds_file" && -r "$creds_file" ]]; then
    # shellcheck disable=SC1090
    source "$creds_file"
    identifier="${OC4D_API_IDENTIFIER:-$identifier}"
    password="${OC4D_API_PASSWORD:-$password}"
  fi

  if [[ -z "$password" ]]; then
    echo "no OC4D_API_PASSWORD set (DB harvest does not need it)" >&2
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to authenticate with the local OC4D API" >&2
    return 1
  fi

  api_base="${api_base%/}"
  response="$(curl -fsS -X POST "${api_base}/api/authentication" \
    -H "Content-Type: application/json" \
    -d "{\"identifier\":\"${identifier}\",\"password\":\"${password}\"}" 2>&1)" || {
    echo "failed to authenticate with local OC4D API at ${api_base}" >&2
    return 1
  }

  token="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "local OC4D API authentication did not return an accessToken" >&2
    return 1
  fi

  printf '%s' "$token"
}

fetch_oc4d_assessment_payload() {
  local api_base="${OC4D_API_BASE_URL:-http://127.0.0.1:3000}"
  local token=""
  local take="${OC4D_API_TAKE:-2000}"
  local start_date="${OC4D_API_START_DATE:-2020-01-01}"
  local out_file="$1"
  local url auth_header=()

  api_base="${api_base%/}"
  url="${api_base}/api/assessment-results?scope=all&take=${take}&startDate=${start_date}"

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to fetch OC4D assessment results" >&2
    return 1
  fi

  token="$(resolve_oc4d_api_token)" || return 1
  auth_header=(-H "Authorization: Bearer ${token}")

  if ! curl -fsS "${auth_header[@]}" "$url" -o "$out_file"; then
    echo "failed to fetch assessment results from ${url}" >&2
    return 1
  fi
  return 0
}
