#!/usr/bin/env bash
# Interactive wrapper for repair_storage_blowup.sh (cdn-auto menus).
# Dry-run first; apply only after explicit confirmation. Never silent.
#
# Usage:
#   ./scripts/data/automation/repair_storage_blowup_menu.sh
#   ./scripts/data/automation/repair_storage_blowup_menu.sh --return ./scripts/troubleshoot/main.sh
#   ./scripts/data/automation/repair_storage_blowup_menu.sh --embedded   # return to caller (install)
#
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

REPAIR="$ROOT/scripts/data/automation/repair_storage_blowup.sh"
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
echo " Repair storage blowup (upload queue / processed / logs)"
echo "=============================================================="
echo ""
echo "Removes corrupt multi‑GiB near-realtime CSVs caused by an old"
echo "processor bug that re-imported prior exports every harvest."
echo "Source logs under /var/log are kept; harvest rebuilds good CSVs."
echo ""
echo -e "${YELLOW}This never runs deletes until you confirm after a dry-run.${NC}"
echo ""

if [[ ! -x "$REPAIR" ]]; then
  chmod +x "$REPAIR" 2>/dev/null || true
fi

run_sudo_repair() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$REPAIR" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$REPAIR" "$@"
  else
    "$REPAIR" "$@"
  fi
}

echo "—— Dry-run (no files deleted) ——"
run_sudo_repair
echo ""

read -r -p "Apply this repair now? [y/N]: " apply
if [[ ! "${apply,,}" =~ ^y(es)?$ ]]; then
  echo "Cancelled. No files deleted."
else
  purge_flags=()
  read -r -p "Also purge ALL near-realtime queue CSVs (any size)? Recommended on affected devices. [Y/n]: " purge
  if [[ ! "${purge,,}" =~ ^n(o)?$ ]]; then
    purge_flags+=(--purge-all-nr-exports)
  fi
  read -r -p "Vacuum systemd journal to 100M? [y/N]: " vac
  if [[ "${vac,,}" =~ ^y(es)?$ ]]; then
    purge_flags+=(--vacuum-journal)
  fi
  echo ""
  echo -e "${RED}Applying repair…${NC}"
  run_sudo_repair --apply "${purge_flags[@]}"
  echo ""
  echo -e "${GREEN}Done.${NC} If timers were stopped, restart them from"
  echo "Data → Automation → Install (or systemctl start v5-log-harvester.timer)."
  echo ""
  # Near-realtime never re-exports past days; offer day backfill after cleanup.
  read -r -p "Also backfill missing S3 days from local source logs? [Y/n]: " do_bf
  if [[ ! "${do_bf,,}" =~ ^n(o)?$ ]]; then
    exec "$ROOT/scripts/data/automation/backfill_s3_days_menu.sh" \
      --return "$RETURN_TO"
  fi
fi

echo ""
read -r -p "Press Enter to continue..."

if (( EMBEDDED )); then
  exit 0
fi
exec "$RETURN_TO"
