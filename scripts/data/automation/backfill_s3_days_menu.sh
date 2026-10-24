#!/usr/bin/env bash
# Interactive wrapper for backfill_s3_days.sh (cdn-auto menus).
# Dry-run first; apply only after explicit confirmation.
#
# Usage:
#   ./scripts/data/automation/backfill_s3_days_menu.sh
#   ./scripts/data/automation/backfill_s3_days_menu.sh --return ./scripts/troubleshoot/storage.sh
#   ./scripts/data/automation/backfill_s3_days_menu.sh --embedded
#
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

BACKFILL="$ROOT/scripts/data/automation/backfill_s3_days.sh"
RETURN_TO="./scripts/data/automation/main.sh"
EMBEDDED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --return) RETURN_TO="${2:?}"; shift ;;
    --embedded) EMBEDDED=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo ""
echo "=============================================================="
echo " Backfill missing S3 days (source logs → day CSV → queue)"
echo "=============================================================="
echo ""
echo "Near-realtime harvest only exports today→now. Past days that"
echo "still exist under /var/log may be missing from S3 after a"
echo "storage blowup repair deleted bloated queue CSVs."
echo ""
echo "This compares local source-log days vs sane S3 objects, then"
echo "can rebuild day-scoped CSVs (size-capped) and flush uploads."
echo ""
echo -e "${YELLOW}Dry-run first; nothing is uploaded until you confirm.${NC}"
echo ""

if [[ ! -x "$BACKFILL" ]]; then
  chmod +x "$BACKFILL" 2>/dev/null || true
fi

run_backfill() {
  # Run as the invoking user (usually pi). backfill_s3_days.sh re-execs as pi
  # if somehow started as root, so processors see user_agents / AWS creds.
  "$BACKFILL" "$@"
}

echo "—— Dry-run (gap report only) ——"
run_backfill
echo ""

read -r -p "Backfill missing days now (enqueue + flush)? [y/N]: " apply
if [[ ! "${apply,,}" =~ ^y(es)?$ ]]; then
  echo "Cancelled. No files enqueued."
else
  echo ""
  echo -e "${RED}Applying backfill + flush…${NC}"
  run_backfill --apply --flush
  echo ""
  echo -e "${GREEN}Done.${NC} Re-check S3 or re-run this menu dry-run to confirm gaps closed."
fi

echo ""
read -r -p "Press Enter to continue..."

if (( EMBEDDED )); then
  exit 0
fi
exec "$RETURN_TO"
