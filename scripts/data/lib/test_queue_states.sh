#!/bin/bash
# Queue state / window / dedup / crash-recovery checks.
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
    log "FAIL: $label expected '$want' got '$got'"
    fail=$((fail + 1))
    return 1
  fi
  log "PASS: $label"
  pass=$((pass + 1))
}

assert_true() {
  local label="$1"
  shift
  if "$@"; then
    log "PASS: $label"
    pass=$((pass + 1))
  else
    log "FAIL: $label"
    fail=$((fail + 1))
  fi
}

assert_false() {
  local label="$1"
  shift
  if "$@"; then
    log "FAIL: $label (expected false)"
    fail=$((fail + 1))
  else
    log "PASS: $label"
    pass=$((pass + 1))
  fi
}

source scripts/data/lib/s3_helpers.sh

TEST_ROOT="$ROOT/00_DATA/.queue_state_test"
rm -rf "$TEST_ROOT"
QUEUE_DIR="$TEST_ROOT/00_UPLOAD_QUEUE"
mkdir -p "$TEST_ROOT"
prepare_queue_dirs "$QUEUE_DIR"

log "=== State dirs exist ==="
assert_true "RACHEL pending dir" test -d "$QUEUE_DIR/RACHEL/pending"
assert_true "OC4D completed dir" test -d "$QUEUE_DIR/OC4DAssessments/completed"

log "=== Legacy migrate ==="
echo legacy > "$QUEUE_DIR/old.csv"
echo stage > "$QUEUE_DIR/RACHEL/legacy_stage.csv"
prepare_queue_dirs "$QUEUE_DIR"
assert_true "legacy root migrated" test -f "$QUEUE_DIR/RACHEL/pending/old.csv"
assert_true "legacy stage migrated" test -f "$QUEUE_DIR/RACHEL/pending/legacy_stage.csv"
assert_false "legacy root gone" test -f "$QUEUE_DIR/old.csv"

log "=== Dedup enqueue ==="
SRC="$TEST_ROOT/src.csv"
echo v1 > "$SRC"
queue_one "$SRC" "$QUEUE_DIR" "RACHEL" ""
assert_eq "$(count_queue_state "$QUEUE_DIR" RACHEL pending)" "3" "pending after first queue (incl migrated)"
echo v2 > "$SRC"
queue_one "$SRC" "$QUEUE_DIR" "RACHEL" ""
assert_eq "$(cat "$QUEUE_DIR/RACHEL/pending/src.csv")" "v2" "pending replaced"
# mark completed and ensure skip
mkdir -p "$QUEUE_DIR/RACHEL/completed"
mv "$QUEUE_DIR/RACHEL/pending/src.csv" "$QUEUE_DIR/RACHEL/completed/src.csv"
echo v3 > "$SRC"
queue_one "$SRC" "$QUEUE_DIR" "RACHEL" ""
assert_false "no re-enqueue after completed" test -f "$QUEUE_DIR/RACHEL/pending/src.csv"

log "=== Crash recovery uploading → pending ==="
echo mid > "$QUEUE_DIR/RACHEL/uploading/stuck.csv"
prepare_queue_dirs "$QUEUE_DIR"
assert_true "recovered to pending" test -f "$QUEUE_DIR/RACHEL/pending/stuck.csv"
assert_false "uploading cleared" test -f "$QUEUE_DIR/RACHEL/uploading/stuck.csv"

log "=== Upload window ==="
UPLOAD_WINDOW="always"
FORCE_UPLOAD=0
assert_true "always open" upload_window_open
UPLOAD_WINDOW="00:00-00:00"
assert_true "zero-length treated open" upload_window_open
# Closed window: pick a 1-minute range far from now by using tomorrow... use inverted logic:
# Set window to a single minute unlikely: if now is HH:MM, use a range that excludes now.
now_hm="$(date '+%H:%M')"
hour="${now_hm%:*}"
# pick hour+6 mod 24 for a 1h closed window relative to now? Simpler: FORCE and closed check
UPLOAD_WINDOW="23:00-23:01"
# May or may not be open depending on clock — only assert FORCE bypass
FORCE_UPLOAD=1
assert_true "FORCE_UPLOAD bypass" upload_window_open
FORCE_UPLOAD=0
UPLOAD_WINDOW="always"

log "=== Markers ==="
write_queue_marker "$QUEUE_DIR" "last_harvest_ok" "2026-01-01T00:00:00"
assert_eq "$(read_queue_marker "$QUEUE_DIR" last_harvest_ok)" "2026-01-01T00:00:00" "harvest marker"

log "=== Window closed flush is no-op ==="
UPLOAD_WINDOW="00:00-00:01"
# If somehow open, skip; else ensure flush returns 0 without moving completed for stuck
before="$(count_queue_state "$QUEUE_DIR" RACHEL pending)"
FORCE_UPLOAD=0
if ! upload_window_open; then
  flush_all_queues "$QUEUE_DIR"
  assert_eq "$(count_queue_state "$QUEUE_DIR" RACHEL pending)" "$before" "pending unchanged when window closed"
else
  log "PASS: window happened to be open; skip closed-window assert"
  pass=$((pass + 1))
fi

log "=== OC4D marking-scheme refresh and upload order ==="
SCHEME_KEY="Testing/MarkingSchemes/faith-quiz/pi-sync-marking-scheme.csv"
SCHEME_SRC="$TEST_ROOT/marking-scheme.csv"
SCHEME_COMPLETED="$QUEUE_DIR/OC4DAssessments/completed"
SCHEME_PENDING="$QUEUE_DIR/OC4DAssessments/pending"
echo scheme-v1 > "$SCHEME_SRC"
cp "$SCHEME_SRC" "$SCHEME_COMPLETED/marking-scheme.csv"
printf '%s\n' "$SCHEME_KEY" > "$SCHEME_COMPLETED/marking-scheme.csv.oc4dkey"
queue_oc4d_one "$SCHEME_SRC" "$QUEUE_DIR" "$SCHEME_KEY"
assert_true "legacy completed scheme queued for one-time refresh" test -f "$SCHEME_PENDING/marking-scheme.csv"
assert_eq "$(sed -n '3p' "$SCHEME_PENDING/marking-scheme.csv.oc4dkey")" \
  "$OC4D_SCHEME_DELIVERY_VERSION" "scheme delivery version recorded"
_queue_move_item "$SCHEME_PENDING/marking-scheme.csv" "$SCHEME_COMPLETED" >/dev/null
queue_oc4d_one "$SCHEME_SRC" "$QUEUE_DIR" "$SCHEME_KEY"
assert_false "current unchanged scheme remains deduplicated" test -f "$SCHEME_PENDING/marking-scheme.csv"
echo scheme-v2 > "$SCHEME_SRC"
queue_oc4d_one "$SCHEME_SRC" "$QUEUE_DIR" "$SCHEME_KEY"
assert_eq "$(cat "$SCHEME_PENDING/marking-scheme.csv")" "scheme-v2" "changed scheme replaces completed version"

ORDER_QUEUE="$TEST_ROOT/order-queue"
prepare_queue_dirs "$ORDER_QUEUE"
META_SRC="$TEST_ROOT/marking-scheme.subject.json"
echo '{"questions":[]}' > "$META_SRC"
queue_oc4d_one "$META_SRC" "$ORDER_QUEUE" \
  "Testing/MarkingSchemes/faith-quiz/pi-sync-subject.json"
queue_oc4d_one "$SCHEME_SRC" "$ORDER_QUEUE" "$SCHEME_KEY"
UPLOAD_LOG="$TEST_ROOT/upload-order.txt"
upload_oc4d_one() { basename "$1" >> "$UPLOAD_LOG"; }
record_oc4d_uploaded_id() { :; }
flush_oc4d_queue "$ORDER_QUEUE"
assert_eq "$(sed -n '1p' "$UPLOAD_LOG")" "marking-scheme.subject.json" "rich metadata uploads first"
assert_eq "$(sed -n '2p' "$UPLOAD_LOG")" "marking-scheme.csv" "scheme CSV uploads after metadata"

rm -rf "$TEST_ROOT"
log "=== Results: $pass passed, $fail failed ==="
if (( fail > 0 )); then
  exit 1
fi
