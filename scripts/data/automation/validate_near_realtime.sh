#!/bin/bash
# Local near-realtime path check (no Pi / no AWS required).
# Proves: rolling window → enqueue → window-gated dispatch → force-flush gate.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

ts() { date '+%H:%M:%S'; }
log() { echo "[$(ts)] $*"; }
pass=0
fail=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" != "$want" ]]; then
    log "FAIL: $label expected='$want' got='$got'"
    fail=$((fail + 1))
    return 1
  fi
  log "PASS: $label"
  pass=$((pass + 1))
}

assert_true() {
  local label="$1"; shift
  if "$@"; then log "PASS: $label"; pass=$((pass + 1))
  else log "FAIL: $label"; fail=$((fail + 1)); fi
}

assert_false() {
  local label="$1"; shift
  if "$@"; then log "FAIL: $label"; fail=$((fail + 1))
  else log "PASS: $label"; pass=$((pass + 1)); fi
}

log "=== time windows ==="
(
  cd scripts/data/automation
  python3 test_time_window.py
)
pass=$((pass + 1))

log "=== queue / window / force flush ==="
# shellcheck disable=SC1091
source scripts/data/lib/s3_helpers.sh

TEST_ROOT="$ROOT/00_DATA/.nr_validate_test"
rm -rf "$TEST_ROOT"
QUEUE_DIR="$TEST_ROOT/00_UPLOAD_QUEUE"
mkdir -p "$TEST_ROOT"
prepare_queue_dirs "$QUEUE_DIR"

SRC="$TEST_ROOT/teach-team-test_nr_20260914_1000_900s_access_logs.csv"
printf 'Access Date,Access Time,bytes\n2026-09-14,10:01:00,100\n' > "$SRC"
queue_one "$SRC" "$QUEUE_DIR" "RACHEL" ""
assert_eq "$(count_queue_state "$QUEUE_DIR" RACHEL pending)" "1" "pending after harvest enqueue"

# completed twin → skip re-enqueue
mkdir -p "$QUEUE_DIR/RACHEL/completed"
cp "$SRC" "$QUEUE_DIR/RACHEL/completed/$(basename "$SRC")"
rm -f "$QUEUE_DIR/RACHEL/pending/$(basename "$SRC")"
queue_one "$SRC" "$QUEUE_DIR" "RACHEL" ""
assert_false "no re-enqueue after completed" test -f "$QUEUE_DIR/RACHEL/pending/$(basename "$SRC")"

rm -f "$QUEUE_DIR/RACHEL/completed/$(basename "$SRC")"
queue_one "$SRC" "$QUEUE_DIR" "RACHEL" ""

UPLOAD_WINDOW="00:00-00:01"
FORCE_UPLOAD=0
if upload_window_open; then
  log "PASS: window coincidentally open; skip closed assert"
  pass=$((pass + 1))
else
  before="$(count_queue_state "$QUEUE_DIR" RACHEL pending)"
  flush_all_queues "$QUEUE_DIR" || true
  assert_eq "$(count_queue_state "$QUEUE_DIR" RACHEL pending)" "$before" "pending held when window closed"
fi

FORCE_UPLOAD=1
assert_true "FORCE_UPLOAD opens window" upload_window_open

write_queue_marker "$QUEUE_DIR" "last_harvest_ok" "2026-09-14T10:00:00"
assert_eq "$(read_queue_marker "$QUEUE_DIR" last_harvest_ok)" "2026-09-14T10:00:00" "harvest marker"

rm -rf "$TEST_ROOT"
log "=== Results: $pass passed, $fail failed ==="
(( fail == 0 ))
echo "NEAR_REALTIME_VALIDATE_OK"
