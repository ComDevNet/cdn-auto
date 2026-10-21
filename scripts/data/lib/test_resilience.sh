#!/bin/bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
source "$ROOT/scripts/data/lib/s3_helpers.sh"
log() { echo "$*"; }
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
QUEUE_DIR="$TEST_ROOT/queue"
prepare_queue_dirs "$QUEUE_DIR"
printf 'original payload\n' > "$QUEUE_DIR/RACHEL/pending/flaky.csv"
printf 'other payload\n' > "$QUEUE_DIR/RACHEL/pending/other.csv"
write_queue_run_sidecar "$QUEUE_DIR/RACHEL/pending/flaky.csv" site_logs_2026_10_21
upload_one() {
  if [[ "$(basename "$1")" == flaky.csv && ! -f "$TEST_ROOT/online" ]]; then return 1; fi
  cat "$1" >> "$TEST_ROOT/delivered"
}
if flush_queue_dir "$QUEUE_DIR/RACHEL/pending" RACHEL; then
  echo 'FAIL: offline transfer reported success'; exit 1
fi
[[ "$(cat "$QUEUE_DIR/RACHEL/pending/flaky.csv")" == 'original payload' ]]
[[ -f "$QUEUE_DIR/RACHEL/pending/flaky.csv.cdnrun" ]]
[[ -f "$QUEUE_DIR/RACHEL/completed/other.csv" ]]
[[ ! -f "$QUEUE_DIR/RACHEL/completed/flaky.csv" ]]
touch "$TEST_ROOT/online"
flush_queue_dir "$QUEUE_DIR/RACHEL/pending" RACHEL
[[ -f "$QUEUE_DIR/RACHEL/completed/flaky.csv" ]]
[[ -f "$QUEUE_DIR/RACHEL/completed/flaky.csv.cdnrun" ]]
[[ ! -f "$QUEUE_DIR/RACHEL/pending/flaky.csv" ]]
[[ "$(cat "$QUEUE_DIR/RACHEL/completed/flaky.csv")" == 'original payload' ]]
echo 'PASS: offline file retained, next file delivered, reconnect retry delivered original payload.'

printf interrupted > "$QUEUE_DIR/ModuleGaze/uploading/interrupted.csv"
printf legacy > "$QUEUE_DIR/RACHEL/failed/legacy.csv"
prepare_queue_dirs "$QUEUE_DIR"
[[ -f "$QUEUE_DIR/ModuleGaze/pending/interrupted.csv" ]]
[[ -f "$QUEUE_DIR/RACHEL/pending/legacy.csv" ]]
echo 'PASS: interrupted and failed files recovered for retry.'

CDN_AUTO_MEMINFO_FILE="$TEST_ROOT/meminfo"
printf 'MemAvailable: 100000 kB\n' > "$CDN_AUTO_MEMINFO_FILE"
if background_memory_ready; then exit 1; fi
printf 'MemAvailable: 1000000 kB\n' > "$CDN_AUTO_MEMINFO_FILE"
background_memory_ready
echo 'PASS: background work waits for safe available memory.'
mkdir -p "$TEST_ROOT/data"
CDN_AUTO_MIN_FREE_KB=100
CDN_AUTO_RESUME_FREE_KB=200
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nroot 1000 950 50 95%% /\n'; }
if harvest_storage_ready "$TEST_ROOT/data" "$QUEUE_DIR"; then exit 1; fi
[[ -f "$QUEUE_DIR/.harvest_storage_paused" ]]
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nroot 1000 820 180 82%% /\n'; }
if harvest_storage_ready "$TEST_ROOT/data" "$QUEUE_DIR"; then exit 1; fi
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nroot 1000 700 300 70%% /\n'; }
harvest_storage_ready "$TEST_ROOT/data" "$QUEUE_DIR"
[[ ! -f "$QUEUE_DIR/.harvest_storage_paused" ]]
unset -f df
echo 'PASS: disk pressure pauses collection, hysteresis prevents flapping, recovery resumes collection.'

OC4D_BUCKET=synthetic-bucket
scheme="$TEST_ROOT/receipt-scheme.csv"
printf 'scheme data' > "$scheme"
scheme_key=Testing/MarkingSchemes/test/scheme.csv
printf '%s\n' "$(sha256sum "$scheme" | awk '{print $1}')" "$scheme_key" "$OC4D_SCHEME_DELIVERY_VERSION" "$OC4D_BUCKET" > "$QUEUE_DIR/OC4DAssessments/completed/receipt-scheme.csv.s3receipt"
queue_oc4d_one "$scheme" "$QUEUE_DIR" "$scheme_key"
[[ ! -f "$QUEUE_DIR/OC4DAssessments/pending/receipt-scheme.csv" ]]
printf 'updated scheme' > "$scheme"
queue_oc4d_one "$scheme" "$QUEUE_DIR" "$scheme_key"
[[ -f "$QUEUE_DIR/OC4DAssessments/pending/receipt-scheme.csv" ]]
echo 'PASS: verified delivery receipt deduplicates unchanged content and permits changed content.'

CDN_AUTO_UPLOAD_TIMEOUT_SECONDS=1
mkdir -p "$TEST_ROOT/bin"
printf '#!/bin/bash\nexec sleep 20\n' > "$TEST_ROOT/bin/aws"
chmod +x "$TEST_ROOT/bin/aws"
export PATH="$TEST_ROOT/bin:$PATH"
printf data > "$TEST_ROOT/timeout.csv"
if background_aws_upload "$TEST_ROOT/timeout.csv" s3://synthetic/test us-east-1; then exit 1; fi
echo 'PASS: stalled upload attempt exits; source remains available for retry.'
[[ "$(cat "$TEST_ROOT/timeout.csv")" == data ]]
