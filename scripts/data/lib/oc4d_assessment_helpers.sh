#!/bin/bash
# OC4D assessment pull helpers: key builder, validation, API fetch, upload/queue routing.

if ! declare -f log >/dev/null 2>&1; then
  log() { echo "[oc4d] $*"; }
fi

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
  printf '%s/OC4DAssessments' "$queue_root"
}

oc4d_sidecar_for_csv() {
  printf '%s.oc4dkey' "$1"
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
  local target_dir base sidecar

  target_dir="$(oc4d_queue_dir "$queue_root")"
  mkdir -p "$target_dir"
  base="$(basename "$file_path")"
  cp -f "$file_path" "$target_dir/$base"
  sidecar="$(oc4d_sidecar_for_csv "$target_dir/$base")"
  printf '%s\n' "$s3_key" > "$sidecar"
  log "[oc4d][queue] Queued $base (key=$s3_key)"
}

flush_oc4d_queue() {
  local queue_root="${1:?queue root required}"
  local queue_dir failed=0 csv sidecar s3_key files=()

  queue_dir="$(oc4d_queue_dir "$queue_root")"
  [[ -d "$queue_dir" ]] || return 0

  shopt -s nullglob
  files=("$queue_dir"/*.csv)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    return 0
  fi

  for csv in "${files[@]}"; do
    sidecar="$(oc4d_sidecar_for_csv "$csv")"
    if [[ ! -f "$sidecar" ]]; then
      log "[oc4d][warn] Missing sidecar for queued file $(basename "$csv"); leaving in queue."
      failed=1
      continue
    fi
    s3_key="$(tr -d '\r' < "$sidecar" | head -n1)"
    if upload_oc4d_one "$csv" "$s3_key"; then
      rm -f "$csv" "$sidecar"
    else
      log "[oc4d] Leaving queued: $(basename "$csv")"
      failed=1
    fi
  done

  return "$failed"
}

resolve_oc4d_api_token() {
  local api_base="${OC4D_API_BASE_URL:-http://127.0.0.1:3000}"
  local token="${OC4D_API_TOKEN:-}"
  local identifier="${OC4D_API_IDENTIFIER:-admin@comdevnet.com}"
  local password="${OC4D_API_PASSWORD:-CDN2025!}"
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
  local out_file="$1"
  local url auth_header=()

  api_base="${api_base%/}"
  url="${api_base}/api/assessment-results?scope=all&take=${take}"

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
