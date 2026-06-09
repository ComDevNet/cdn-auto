#!/bin/bash
# Non-interactive OC4D assessment pull + upload (no upload menu).

set -euo pipefail

CONFIG_FILE="config/automation.conf"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$PROJECT_ROOT"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/data/lib/oc4d_assessment_helpers.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

OC4D_ASSESSMENTS_ENABLED="${OC4D_ASSESSMENTS_ENABLED:-0}"
OC4D_API_BASE_URL="${OC4D_API_BASE_URL:-http://127.0.0.1:3000}"
OC4D_API_TOKEN="${OC4D_API_TOKEN:-}"
OC4D_PARENT_ORG="${OC4D_PARENT_ORG:-Home-Schooling}"
OC4D_SOURCE_DIR="${OC4D_SOURCE_DIR:-}"
OC4D_STUDENT_MAP_FILE="${OC4D_STUDENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/student-map.csv}"
OC4D_ASSESSMENT_MAP_FILE="${OC4D_ASSESSMENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/assessment-map.csv}"
OC4D_STATE_FILE="${OC4D_STATE_FILE:-$PROJECT_ROOT/00_DATA/00_OC4D_ASSESSMENTS/uploaded-state.json}"
OC4D_UNASSIGNED_STUDENT_ID="${OC4D_UNASSIGNED_STUDENT_ID:-unassigned}"
QUEUE_DIR="$PROJECT_ROOT/00_DATA/00_UPLOAD_QUEUE"

if ! oc4d_assessments_enabled; then
  echo "OC4D assessments are disabled."
  exit 2
fi

ONLINE=0
if getent hosts s3.amazonaws.com >/dev/null 2>&1; then
  ONLINE=1
  log "[online] Flushing OC4D assessment queue..."
  flush_oc4d_queue "$QUEUE_DIR" || log "[warn] Some queued OC4D files could not be flushed."
fi

log "[oc4d] Running assessment processor..."
OC4D_API_BASE_URL="$OC4D_API_BASE_URL" \
OC4D_API_TOKEN="$OC4D_API_TOKEN" \
OC4D_PARENT_ORG="$OC4D_PARENT_ORG" \
OC4D_SOURCE_DIR="$OC4D_SOURCE_DIR" \
OC4D_STUDENT_MAP_FILE="$OC4D_STUDENT_MAP_FILE" \
OC4D_ASSESSMENT_MAP_FILE="$OC4D_ASSESSMENT_MAP_FILE" \
OC4D_STATE_FILE="$OC4D_STATE_FILE" \
OC4D_UNASSIGNED_STUDENT_ID="$OC4D_UNASSIGNED_STUDENT_ID" \
  python3 "scripts/data/process/processors/assessment.py"

manifest_path="$(find "$PROJECT_ROOT/00_DATA/00_OC4D_ASSESSMENTS" -maxdepth 2 -type f -name 'manifest.json' | sort | tail -n1)"
if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
  echo "No manifest.json produced."
  exit 1
fi

uploaded=0
queued=0
failed=0
schemes_uploaded=0
new_uploaded_ids=()

while IFS=$'\t' read -r file_path s3_key _result_id; do
  [[ -n "$file_path" && -f "$file_path" ]] || continue
  log "[scheme-meta] $file_path -> s3://$(oc4d_bucket_name)/$s3_key"
  if (( ONLINE )); then
    if upload_oc4d_one "$file_path" "$s3_key"; then
      uploaded=$((uploaded + 1))
    else
      queue_oc4d_one "$file_path" "$QUEUE_DIR" "$s3_key"
      queued=$((queued + 1))
      failed=$((failed + 1))
    fi
  else
    queue_oc4d_one "$file_path" "$QUEUE_DIR" "$s3_key"
    queued=$((queued + 1))
  fi
done < <(
  python3 - "$manifest_path" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in manifest.get("marking_schemes", []):
    subject_json = entry.get("subject_json", "")
    subject_s3_key = entry.get("subject_s3_key", "")
    if subject_json and subject_s3_key:
        print("\t".join([subject_json, subject_s3_key, ""]))
PY
)

while IFS=$'\t' read -r csv_path s3_key _result_id; do
  [[ -n "$csv_path" && -f "$csv_path" ]] || continue
  log "[scheme] $csv_path -> s3://$(oc4d_bucket_name)/$s3_key"
  if (( ONLINE )); then
    if upload_oc4d_one "$csv_path" "$s3_key"; then
      schemes_uploaded=$((schemes_uploaded + 1))
      uploaded=$((uploaded + 1))
    else
      queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
      queued=$((queued + 1))
      failed=$((failed + 1))
    fi
  else
    queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
    queued=$((queued + 1))
  fi
done < <(
  python3 - "$manifest_path" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in manifest.get("marking_schemes", []):
    print("\t".join([entry.get("csv", ""), entry.get("s3_key", ""), ""]))
PY
)

while IFS=$'\t' read -r csv_path s3_key result_id; do
  [[ -n "$csv_path" && -f "$csv_path" ]] || continue
  log "[result] $csv_path -> s3://$(oc4d_bucket_name)/$s3_key"
  if (( ONLINE )); then
    if upload_oc4d_one "$csv_path" "$s3_key"; then
      uploaded=$((uploaded + 1))
      [[ -n "$result_id" ]] && new_uploaded_ids+=("$result_id")
    else
      queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
      queued=$((queued + 1))
      failed=$((failed + 1))
    fi
  else
    queue_oc4d_one "$csv_path" "$QUEUE_DIR" "$s3_key"
    queued=$((queued + 1))
  fi
done < <(
  python3 - "$manifest_path" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in manifest.get("ready", []):
    print("\t".join([entry.get("csv", ""), entry.get("s3_key", ""), entry.get("result_id", "")]))
PY
)

failed=$((failed + $(python3 - "$manifest_path" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8")).get("failed", [])))
PY
)))

if (( ${#new_uploaded_ids[@]} > 0 )); then
  python3 - "$OC4D_STATE_FILE" "${new_uploaded_ids[@]}" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
ids = [item for item in sys.argv[2:] if item]
uploaded = set()
if state_path.exists():
    try:
        uploaded = set(json.loads(state_path.read_text(encoding="utf-8")).get("uploadedIds", []))
    except json.JSONDecodeError:
        uploaded = set()
uploaded.update(ids)
state_path.parent.mkdir(parents=True, exist_ok=True)
state_path.write_text(json.dumps({"uploadedIds": sorted(uploaded)}, indent=2) + "\n", encoding="utf-8")
PY
fi

log "OC4D assessment run complete."
echo "Uploaded: $uploaded (marking schemes: $schemes_uploaded) | Queued: $queued | Failed: $failed"
echo "Manifest: $manifest_path"
