#!/bin/bash
# Route verification for log folder cleanup helpers and queue sidecars.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

source scripts/data/lib/cleanup_helpers.sh
source scripts/data/lib/s3_helpers.sh

ts() { date '+%H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

pass=0
fail=0

assert_dir_absent() {
  local path="$1"
  local label="$2"
  if [[ -d "$path" ]]; then
    log "FAIL: $label still exists at $path"
    fail=$((fail + 1))
    return 1
  fi
  log "PASS: $label removed"
  pass=$((pass + 1))
}

assert_dir_present() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" ]]; then
    log "FAIL: $label missing at $path"
    fail=$((fail + 1))
    return 1
  fi
  log "PASS: $label kept"
  pass=$((pass + 1))
}

assert_eq() {
  local got="$1"
  local want="$2"
  local label="$3"
  if [[ "$got" != "$want" ]]; then
    log "FAIL: $label expected '$want' got '$got'"
    fail=$((fail + 1))
    return 1
  fi
  log "PASS: $label"
  pass=$((pass + 1))
}

TEST_ROOT="$ROOT/00_DATA/.cleanup_route_test"
rm -rf "$TEST_ROOT"
DATA_DIR="$TEST_ROOT/00_DATA"
PROCESSED_ROOT="$TEST_ROOT/00_PROCESSED"
QUEUE_DIR="$TEST_ROOT/00_UPLOAD_QUEUE"
mkdir -p "$DATA_DIR" "$PROCESSED_ROOT" "$QUEUE_DIR/RACHEL" "$QUEUE_DIR/ModuleGaze"
export CDN_AUTO_PROCESSED_ROOT="$PROCESSED_ROOT"

log "=== Route 1: raw cleanup after successful processing ==="
mkdir -p "$DATA_DIR/site_logs_2025_06_22"
echo raw > "$DATA_DIR/site_logs_2025_06_22/access.log"
cleanup_raw_run_folder "$DATA_DIR" "site_logs_2025_06_22/"
assert_dir_absent "$DATA_DIR/site_logs_2025_06_22" "raw folder with trailing slash name"

log "=== Route 2: processed cleanup on empty window ==="
mkdir -p "$PROCESSED_ROOT/site_logs_2025_06_23"
echo summary > "$PROCESSED_ROOT/site_logs_2025_06_23/summary.csv"
cleanup_processed_run_folder "$PROCESSED_ROOT" "site_logs_2025_06_23"
assert_dir_absent "$PROCESSED_ROOT/site_logs_2025_06_23" "processed folder after empty window"

log "=== Route 3: reserved names are rejected ==="
mkdir -p "$DATA_DIR/00_PROCESSED"
cleanup_raw_run_folder "$DATA_DIR" "00_PROCESSED"
assert_dir_present "$DATA_DIR/00_PROCESSED" "reserved folder 00_PROCESSED"

log "=== Route 4: modulegaze run name validation ==="
assert_eq "$(normalize_log_run_name "lab_modulegaze_logs_2025_06_22")" "lab_modulegaze_logs_2025_06_22" "modulegaze run name"

log "=== Route 5: queue sidecar targets exact processed run ==="
mkdir -p "$PROCESSED_ROOT/site_logs_2025_06_24" "$PROCESSED_ROOT/site_logs_2025_06_25"
echo one > "$PROCESSED_ROOT/site_logs_2025_06_24/site_daily_access_logs.csv"
echo two > "$PROCESSED_ROOT/site_logs_2025_06_25/site_daily_access_logs.csv"
queued_csv="$QUEUE_DIR/RACHEL/site_daily_access_logs.csv"
cp "$PROCESSED_ROOT/site_logs_2025_06_24/site_daily_access_logs.csv" "$queued_csv"
write_queue_run_sidecar "$queued_csv" "site_logs_2025_06_24"
assert_eq "$(read_queue_run_sidecar "$queued_csv")" "site_logs_2025_06_24" "queue sidecar read"
cleanup_processed_for_uploaded_csv "$PROCESSED_ROOT" "$queued_csv"
assert_dir_absent "$PROCESSED_ROOT/site_logs_2025_06_24" "sidecar-selected processed folder"
assert_dir_present "$PROCESSED_ROOT/site_logs_2025_06_25" "other processed folder with same csv basename"

log "=== Route 6: basename fallback when sidecar missing ==="
mkdir -p "$PROCESSED_ROOT/site_logs_2025_06_26"
echo data > "$PROCESSED_ROOT/site_logs_2025_06_26/site_weekly_access_logs.csv"
queued_csv="$QUEUE_DIR/RACHEL/site_weekly_access_logs.csv"
cp "$PROCESSED_ROOT/site_logs_2025_06_26/site_weekly_access_logs.csv" "$queued_csv"
cleanup_processed_for_uploaded_csv "$PROCESSED_ROOT" "$queued_csv"
assert_dir_absent "$PROCESSED_ROOT/site_logs_2025_06_26" "basename fallback processed folder"

log "=== Route 7: queue_one writes sidecar for RACHEL ==="
mkdir -p "$PROCESSED_ROOT/site_logs_2025_06_27"
echo data > "$PROCESSED_ROOT/site_logs_2025_06_27/site_daily_access_logs.csv"
queue_one "$PROCESSED_ROOT/site_logs_2025_06_27/site_daily_access_logs.csv" "$QUEUE_DIR" "RACHEL" "site_logs_2025_06_27"
assert_eq "$(read_queue_run_sidecar "$QUEUE_DIR/RACHEL/site_daily_access_logs.csv")" "site_logs_2025_06_27" "queue_one sidecar"

log "=== Route 8: Kolibri queue does not write sidecar ==="
mkdir -p "$QUEUE_DIR/Kolibri"
echo k > "$TEST_ROOT/kolibri.csv"
queue_one "$TEST_ROOT/kolibri.csv" "$QUEUE_DIR" "Kolibri" "ignored_run"
if [[ -f "$QUEUE_DIR/Kolibri/kolibri.csv.cdnrun" ]]; then
  log "FAIL: Kolibri queue should not create sidecar"
  fail=$((fail + 1))
else
  log "PASS: Kolibri queue has no sidecar"
  pass=$((pass + 1))
fi

log "=== Route 9: missing processed folder is a no-op ==="
cleanup_processed_run_folder "$PROCESSED_ROOT" "site_logs_2099_01_01"
log "PASS: missing processed folder did not error"

log "=== Route 10: invalid run name is rejected ==="
if normalize_log_run_name "../logs" >/dev/null 2>&1; then
  log "FAIL: path traversal run name should be rejected"
  fail=$((fail + 1))
else
  log "PASS: path traversal run name rejected"
  pass=$((pass + 1))
fi

log "=== Route 11: cleanup already-removed folder is a no-op ==="
cleanup_processed_run_folder "$PROCESSED_ROOT" "site_logs_2025_06_23"
log "PASS: repeat processed cleanup did not error"

rm -rf "$TEST_ROOT"
log "=== Results: $pass passed, $fail failed ==="
if (( fail > 0 )); then
  exit 1
fi
