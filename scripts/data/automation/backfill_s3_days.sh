#!/usr/bin/env bash
# Backfill missing calendar days from local source logs into S3.
#
# Near-realtime harvest only exports today→now. After storage blowup repair
# deletes bloated queue CSVs, past days that still exist under /var/log may
# never re-upload automatically. This tool compares local source-log days vs
# sane S3 objects for the configured RACHEL/ModuleGaze prefixes, then (with
# --apply) builds day-scoped CSVs, enqueues them (size-capped), and optionally
# flushes the upload queue.
#
# Dry-run by default. Never uploads multi-GiB junk.
#
# Usage (from repo root):
#   ./scripts/data/automation/backfill_s3_days.sh
#   ./scripts/data/automation/backfill_s3_days.sh --apply --flush
#   ./scripts/data/automation/backfill_s3_days.sh --apply --days 2026-10-09,2026-10-10
#   ./scripts/data/automation/backfill_s3_days.sh --max-mb 50 --sane-mb 50
#
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

# Processors need packages installed for the service user (pi), not root.
# Re-exec as that user when invoked via sudo so user_agents / AWS creds resolve.
SERVICE_USER="${CDN_AUTO_SERVICE_USER:-pi}"
if [[ "$(id -u)" -eq 0 && "${CDN_AUTO_BACKFILL_AS_ROOT:-0}" != "1" ]]; then
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    exec sudo -u "$SERVICE_USER" -H -- "$0" "$@"
  fi
fi

# Windows edits leave CRLF; bash then dies on $'\r' while sourcing helpers.
find "$ROOT/scripts" -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# shellcheck disable=SC1091
source "$ROOT/scripts/data/lib/s3_helpers.sh"

APPLY=0
FLUSH=0
MAX_MB="${CDN_AUTO_BACKFILL_MAX_MB:-${CDN_AUTO_REPAIR_MAX_MB:-50}}"
SANE_MB="${CDN_AUTO_BACKFILL_SANE_MB:-50}"
INCLUDE_TODAY=0
DAYS_OVERRIDE=""
STREAMS="RACHEL,ModuleGaze"
SKIP_S3=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --flush) FLUSH=1 ;;
    --max-mb) MAX_MB="${2:?}"; shift ;;
    --sane-mb) SANE_MB="${2:?}"; shift ;;
    --include-today) INCLUDE_TODAY=1 ;;
    --days) DAYS_OVERRIDE="${2:?}"; shift ;;
    --streams) STREAMS="${2:?}"; shift ;;
    --skip-s3) SKIP_S3=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if ! [[ "$MAX_MB" =~ ^[0-9]+$ ]] || (( MAX_MB < 1 )); then
  echo "Invalid --max-mb: $MAX_MB" >&2
  exit 2
fi
if ! [[ "$SANE_MB" =~ ^[0-9]+$ ]] || (( SANE_MB < 1 )); then
  echo "Invalid --sane-mb: $SANE_MB" >&2
  exit 2
fi

MAX_BYTES=$((MAX_MB * 1024 * 1024))
SANE_BYTES=$((SANE_MB * 1024 * 1024))
CONFIG_FILE="$ROOT/config/automation.conf"
DATA_DIR="${CDN_AUTO_DATA_DIR:-$ROOT/00_DATA}"
PROCESSED_ROOT="${CDN_AUTO_PROCESSED_ROOT:-$DATA_DIR/00_PROCESSED}"
QUEUE_DIR="${CDN_AUTO_QUEUE_DIR:-$DATA_DIR/00_UPLOAD_QUEUE}"
FILTER_DAY="$ROOT/scripts/data/automation/filter_day.py"
COVERAGE_PY="$ROOT/scripts/data/automation/s3_day_coverage.py"
TMP_DIR="$(mktemp -d /tmp/cdn_auto_backfill.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[backfill $(ts)] $*"; }

load_config() {
  local src="$CONFIG_FILE"
  local tmp=""
  if [[ -r "$src" ]]; then
    # shellcheck disable=SC1090
    source "$src"
    log "[config] Loaded: $src"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    tmp="$TMP_DIR/automation.conf"
    if sudo -n cat "$src" > "$tmp" 2>/dev/null || sudo cat "$src" > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp"
      # shellcheck disable=SC1090
      source "$tmp"
      log "[config] Loaded (sudo): $src"
      return 0
    fi
  fi
  log "[error] Cannot read config: $src"
  exit 1
}
load_config

[[ -n "${AWS_PROFILE:-}" ]] && export AWS_PROFILE || unset AWS_PROFILE
[[ -n "${AWS_REGION:-}" ]] && export AWS_DEFAULT_REGION="$AWS_REGION" || unset AWS_DEFAULT_REGION

SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
RACHEL_SUBFOLDER="${RACHEL_SUBFOLDER:-}"
MODULEGAZE_SUBFOLDER="${MODULEGAZE_SUBFOLDER:-}"
MODULEGAZE_ENABLED="${MODULEGAZE_ENABLED:-1}"
MODULEGAZE_API_BASE_URL="${MODULEGAZE_API_BASE_URL:-http://127.0.0.1:3002}"
MODULEGAZE_MODULE_MAP_FILE="${MODULEGAZE_MODULE_MAP_FILE:-$ROOT/config/oc4d/module-map.csv}"

export CDN_AUTO_PROCESSED_ROOT="$PROCESSED_ROOT"
export CDN_AUTO_MAX_QUEUE_FILE_BYTES="$MAX_BYTES"
prepare_queue_dirs "$QUEUE_DIR"

TODAY="$(date '+%Y-%m-%d')"

echo "=============================================="
echo " CDN-auto S3 day coverage / backfill"
echo " Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo " Device: $DEVICE_LOCATION | server=$SERVER_VERSION"
echo " Max CSV: ${MAX_MB} MiB | Sane coverage: ${SANE_MB} MiB"
echo " Bucket: $S3_BUCKET | S3_SUBFOLDER=${S3_SUBFOLDER:-<none>}"
echo " RACHEL_SUBFOLDER=${RACHEL_SUBFOLDER:-<none>}"
echo "=============================================="
echo

# --- discover local source days ------------------------------------------------

discover_rachel_days() {
  local d
  case "$SERVER_VERSION" in
    v1|server\ v4|v4)
      # Apache rotated logs rarely encode YYYY-MM-DD; skip auto-discovery.
      return 0
      ;;
    v2|server\ v5|v5|server\ v6|v6)
      for f in /var/log/oc4d/oc4d-????-??-??.log /var/log/oc4d/oc4d-????-??-??.log.gz; do
        [[ -e "$f" ]] || continue
        [[ "$f" == *exceptions* ]] && continue
        d="$(basename "$f" | sed -E 's/^oc4d-([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')"
        [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && printf '%s\n' "$d"
      done
      ;;
    v3|dhub|d-hub)
      # dhub logs not date-named; skip auto-discovery.
      return 0
      ;;
  esac
}

discover_modulegaze_days() {
  local d f
  [[ "$MODULEGAZE_ENABLED" == "1" ]] || return 0
  [[ -d /var/log/modulegaze ]] || return 0
  # Match runner: sessions archives only (access zips alone produce 0 rows).
  for f in /var/log/modulegaze/modulegaze-sessions-????-??-??.log.zip; do
    [[ -e "$f" ]] || continue
    # Skip empty / tiny archives (no recoverable sessions).
    [[ "$(wc -c < "$f" | tr -d ' ')" -ge 32 ]] || continue
    d="$(basename "$f" | sed -E 's/.*([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && printf '%s\n' "$d"
  done
}

rachel_processor() {
  case "$SERVER_VERSION" in
    v1|v4) echo "scripts/data/process/processors/log.py" ;;
    v2|v5|server\ v5)
      case "$PYTHON_SCRIPT" in
        cape_coast_d) echo "scripts/data/process/processors/castle.py" ;;
        *) echo "scripts/data/process/processors/logv2.py" ;;
      esac
      ;;
    v3|dhub|d-hub) echo "scripts/data/process/processors/dhub.py" ;;
    server\ v6|v6) echo "scripts/data/process/processors/log-v6.py" ;;
    *) echo "" ;;
  esac
}

s3_prefix_for() {
  local stage="$1"
  local base extra=""
  base="$(remote_base_path)"
  if [[ "$stage" == "RACHEL" && -n "${RACHEL_SUBFOLDER:-}" ]]; then
    extra="$RACHEL_SUBFOLDER"
  elif [[ "$stage" == "ModuleGaze" && -n "${MODULEGAZE_SUBFOLDER:-}" ]]; then
    extra="$MODULEGAZE_SUBFOLDER"
  fi
  if [[ -n "$extra" ]]; then
    join_path "$(join_path "$base" "$stage")" "$extra/"
  else
    join_path "$base" "$stage/"
  fi
}

# List S3 into a file — NEVER pipe aws into python while feeding a heredoc.
list_s3_to_file() {
  local prefix="$1"
  local out="$2"
  : > "$out"
  if (( SKIP_S3 )); then
    log "[s3] --skip-s3: treating all local days as gaps"
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    log "[error] aws CLI not found"
    return 1
  fi
  log "[s3] Listing $prefix"
  # Write listing to file first (fixes stdin/heredoc bug that returned 0 objects).
  if ! aws s3 ls "$prefix" --recursive > "$out" 2>"$TMP_DIR/aws_err.txt"; then
    log "[warn] aws s3 ls failed for $prefix: $(tr '\n' ' ' < "$TMP_DIR/aws_err.txt")"
    : > "$out"
    return 1
  fi
  local n
  n="$(wc -l < "$out" | tr -d ' ')"
  log "[s3] ${n} listing line(s) -> $out"
  return 0
}

filter_candidate_days() {
  local day
  while IFS= read -r day; do
    [[ -z "$day" ]] && continue
    if (( ! INCLUDE_TODAY )) && [[ "$day" == "$TODAY" ]]; then
      continue
    fi
    printf '%s\n' "$day"
  done
}

# --- collect local days --------------------------------------------------------

mapfile -t RACHEL_LOCAL_DAYS < <(
  if [[ -n "$DAYS_OVERRIDE" ]]; then
    echo "$DAYS_OVERRIDE" | tr ',' '\n'
  else
    discover_rachel_days
  fi | filter_candidate_days | sort -u
)

mapfile -t MG_LOCAL_DAYS < <(
  if [[ -n "$DAYS_OVERRIDE" ]]; then
    echo "$DAYS_OVERRIDE" | tr ',' '\n'
  else
    discover_modulegaze_days
  fi | filter_candidate_days | sort -u
)

log "Local RACHEL source days: ${#RACHEL_LOCAL_DAYS[@]} (${RACHEL_LOCAL_DAYS[*]:-<none>})"
log "Local ModuleGaze source days: ${#MG_LOCAL_DAYS[@]} (${MG_LOCAL_DAYS[*]:-<none>})"

# --- S3 coverage ---------------------------------------------------------------

RACHEL_GAPS=()
MG_GAPS=()

want_rachel=0
want_mg=0
[[ ",$STREAMS," == *",RACHEL,"* ]] && want_rachel=1
[[ ",$STREAMS," == *",ModuleGaze,"* ]] && want_mg=1

if (( want_rachel )) && ((${#RACHEL_LOCAL_DAYS[@]} > 0)); then
  rachel_prefix="$(s3_prefix_for RACHEL)"
  rachel_ls="$TMP_DIR/s3_rachel.txt"
  list_s3_to_file "$rachel_prefix" "$rachel_ls" || true
  local_csv="$(IFS=,; echo "${RACHEL_LOCAL_DAYS[*]}")"
  mapfile -t RACHEL_GAPS < <(
    python3 "$COVERAGE_PY" "$rachel_ls" \
      --sane-bytes "$SANE_BYTES" \
      --device "$DEVICE_LOCATION" \
      --local-days "$local_csv" \
      --summary \
      --report-gaps
  )
fi

if (( want_mg )) && ((${#MG_LOCAL_DAYS[@]} > 0)) && [[ "$MODULEGAZE_ENABLED" == "1" ]]; then
  mg_prefix="$(s3_prefix_for ModuleGaze)"
  mg_ls="$TMP_DIR/s3_mg.txt"
  list_s3_to_file "$mg_prefix" "$mg_ls" || true
  local_csv="$(IFS=,; echo "${MG_LOCAL_DAYS[*]}")"
  mapfile -t MG_GAPS < <(
    python3 "$COVERAGE_PY" "$mg_ls" \
      --sane-bytes "$SANE_BYTES" \
      --device "$DEVICE_LOCATION" \
      --local-days "$local_csv" \
      --summary \
      --report-gaps
  )
fi

echo
log "RACHEL gaps (local data, no sane S3): ${#RACHEL_GAPS[@]} (${RACHEL_GAPS[*]:-<none>})"
log "ModuleGaze gaps: ${#MG_GAPS[@]} (${MG_GAPS[*]:-<none>})"
echo

if (( ${#RACHEL_GAPS[@]} == 0 && ${#MG_GAPS[@]} == 0 )); then
  log "No gaps to backfill. Done."
  exit 0
fi

if (( ! APPLY )); then
  log "Dry-run only. Re-run with --apply to build day CSVs, enqueue, and (optionally) --flush."
  log "Example: ./scripts/data/automation/backfill_s3_days.sh --apply --flush"
  exit 0
fi

# --- apply recovery ------------------------------------------------------------

enqueued=0
skipped=0
failed=0

recover_rachel_day() {
  local day="$1"
  # Must match cleanup_helpers is_log_run_name: {device}_logs_YYYY_MM_DD
  local ymd="${day:0:4}_${day:5:2}_${day:8:2}"
  local folder="${DEVICE_LOCATION}_logs_${ymd}"
  local collect="$DATA_DIR/$folder"
  local processed="$PROCESSED_ROOT/$folder"
  local processor src_log src_gz out_name csv sz

  processor="$(rachel_processor)"
  if [[ -z "$processor" ]]; then
    log "[rachel][skip] no processor for SERVER_VERSION=$SERVER_VERSION"
    skipped=$((skipped + 1))
    return 0
  fi

  log "[rachel] backfill day=$day"
  rm -rf "$collect" "$processed"
  mkdir -p "$collect"

  src_log="/var/log/oc4d/oc4d-${day}.log"
  src_gz="/var/log/oc4d/oc4d-${day}.log.gz"
  case "$SERVER_VERSION" in
    v1|server\ v4|v4)
      log "[rachel][skip] apache v1/v4 auto day backfill not supported; use --days with manual collect"
      skipped=$((skipped + 1))
      return 0
      ;;
    v3|dhub|d-hub)
      log "[rachel][skip] dhub auto day backfill not supported"
      skipped=$((skipped + 1))
      return 0
      ;;
    *)
      if [[ -f "$src_log" && -s "$src_log" ]]; then
        cp -- "$src_log" "$collect/"
      elif [[ -f "$src_gz" && -s "$src_gz" ]]; then
        gzip -cd "$src_gz" > "$collect/oc4d-${day}_archived.log"
      else
        log "[rachel][skip] no source log for $day"
        skipped=$((skipped + 1))
        rm -rf "$collect"
        return 0
      fi
      ;;
  esac

  if ! python3 "$processor" "$folder"; then
    log "[rachel][fail] processor failed for $day"
    failed=$((failed + 1))
    rm -rf "$collect" "$processed"
    return 0
  fi
  rm -rf "$collect"

  if [[ ! -s "$processed/summary.csv" ]]; then
    log "[rachel][skip] empty summary for $day"
    skipped=$((skipped + 1))
    rm -rf "$processed"
    return 0
  fi

  if ! out_name="$(python3 "$FILTER_DAY" "$processed" "$DEVICE_LOCATION" "$day" "access_logs")"; then
    log "[rachel][skip] filter produced nothing for $day"
    skipped=$((skipped + 1))
    rm -rf "$processed"
    return 0
  fi

  csv="$processed/$out_name"
  sz="$(wc -c < "$csv" | tr -d ' ')"
  log "[rachel] csv=$out_name bytes=$sz"
  if (( sz > MAX_BYTES )); then
    log "[rachel][ABORT] $out_name exceeds ${MAX_MB} MiB — not enqueueing (corrupt/blowup risk)"
    failed=$((failed + 1))
    rm -rf "$processed"
    return 1
  fi

  if queue_one "$csv" "$QUEUE_DIR" "RACHEL" "$folder"; then
    enqueued=$((enqueued + 1))
    log "[rachel] enqueued $out_name"
  else
    failed=$((failed + 1))
    log "[rachel][fail] enqueue refused for $out_name"
  fi
}

recover_modulegaze_day() {
  local day="$1"
  # Must match cleanup_helpers: {device}_modulegaze_logs_YYYY_MM_DD
  local ymd="${day:0:4}_${day:5:2}_${day:8:2}"
  local folder="${DEVICE_LOCATION}_modulegaze_logs_${ymd}"
  local collect="$DATA_DIR/$folder"
  local processed="$PROCESSED_ROOT/$folder"
  local zip szip out_name csv sz

  log "[modulegaze] backfill day=$day"
  rm -rf "$collect" "$processed"
  mkdir -p "$collect"

  zip="/var/log/modulegaze/modulegaze-sessions-${day}.log.zip"
  szip="/var/log/modulegaze/modulegaze-access-${day}.log.zip"
  if [[ -f "$zip" ]]; then
    cp -- "$zip" "$collect/"
  else
    log "[modulegaze][skip] no sessions zip for $day"
    skipped=$((skipped + 1))
    rm -rf "$collect"
    return 0
  fi
  [[ -f "$szip" ]] && cp -- "$szip" "$collect/" || true

  if ! find "$collect" -type f | grep -q .; then
    log "[modulegaze][skip] collect empty"
    skipped=$((skipped + 1))
    rm -rf "$collect"
    return 0
  fi

  if ! MODULEGAZE_API_BASE_URL="$MODULEGAZE_API_BASE_URL" \
    MODULEGAZE_MODULE_MAP_FILE="$MODULEGAZE_MODULE_MAP_FILE" \
    python3 "scripts/data/process/processors/modulegaze.py" "$folder"; then
    log "[modulegaze][fail] processor failed for $day"
    failed=$((failed + 1))
    rm -rf "$collect" "$processed"
    return 0
  fi
  rm -rf "$collect"

  if [[ ! -s "$processed/summary.csv" ]]; then
    log "[modulegaze][skip] empty summary"
    skipped=$((skipped + 1))
    rm -rf "$processed"
    return 0
  fi

  if ! out_name="$(python3 "$FILTER_DAY" "$processed" "$DEVICE_LOCATION" "$day" "modulegaze_logs")"; then
    log "[modulegaze][skip] no rows for $day"
    skipped=$((skipped + 1))
    rm -rf "$processed"
    return 0
  fi

  csv="$processed/$out_name"
  sz="$(wc -c < "$csv" | tr -d ' ')"
  log "[modulegaze] csv=$out_name bytes=$sz"
  if (( sz > MAX_BYTES )); then
    log "[modulegaze][ABORT] exceeds ${MAX_MB} MiB — not enqueueing"
    failed=$((failed + 1))
    rm -rf "$processed"
    return 1
  fi

  if queue_one "$csv" "$QUEUE_DIR" "ModuleGaze" "$folder"; then
    enqueued=$((enqueued + 1))
    log "[modulegaze] enqueued $out_name"
  else
    failed=$((failed + 1))
    log "[modulegaze][fail] enqueue refused"
  fi
}

for day in "${RACHEL_GAPS[@]}"; do
  recover_rachel_day "$day" || true
done

if [[ "$MODULEGAZE_ENABLED" == "1" ]]; then
  for day in "${MG_GAPS[@]}"; do
    recover_modulegaze_day "$day" || true
  done
fi

echo
log "Enqueued=$enqueued skipped=$skipped failed=$failed"
log "Pending RACHEL=$(count_queue_state "$QUEUE_DIR" RACHEL pending) ModuleGaze=$(count_queue_state "$QUEUE_DIR" ModuleGaze pending)"

if (( FLUSH )); then
  log "Flushing upload queue (FORCE_UPLOAD=1)…"
  if FORCE_UPLOAD=1 "$ROOT/scripts/data/automation/flush_queue.sh"; then
    log "Flush OK"
  else
    log "[warn] Flush reported failures; check connectivity / aws creds"
    exit 1
  fi
else
  log "Queued files left pending. Run flush_queue.sh or pass --flush."
fi

log "Done."
