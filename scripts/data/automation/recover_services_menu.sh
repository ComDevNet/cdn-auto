#!/usr/bin/env bash
# Interactive wrapper for recover_services_after_repair.sh (cdn-auto menus).
# Dry-run first; apply only after confirmation. DB restore is a second confirm.
#
# Usage:
#   ./scripts/data/automation/recover_services_menu.sh
#   ./scripts/data/automation/recover_services_menu.sh --return ./scripts/troubleshoot/storage.sh
#   ./scripts/data/automation/recover_services_menu.sh --embedded
#
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

RECOVER="$ROOT/scripts/data/automation/recover_services_after_repair.sh"
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
echo " Recover services (post storage / disk incident)"
echo "=============================================================="
echo ""
echo "Starts/enables units that exist on this device (oc4d, docker,"
echo "service-monitor, harvest timers, hotspot/zerotier, modulegaze…),"
echo "brings up oc4d_db if needed, and can restore Postgres from the"
echo "newest non-empty backup under /var/backups/oc4d/database/."
echo ""
echo -e "${YELLOW}Dry-run first. Nothing is changed until you confirm.${NC}"
echo ""

if [[ ! -x "$RECOVER" ]]; then
  chmod +x "$RECOVER" 2>/dev/null || true
fi

run_sudo_recover() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$RECOVER" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$RECOVER" "$@"
  else
    "$RECOVER" "$@"
  fi
}

DRY_OUT="$(mktemp)"
trap 'rm -f "$DRY_OUT"' EXIT

echo "—— Dry-run (no changes) ——"
set +e
run_sudo_recover 2>&1 | tee "$DRY_OUT"
set -e
echo ""

needs_db_restore=0
if grep -qE 'Candidate restore:|DB restore available' "$DRY_OUT"; then
  needs_db_restore=1
fi

read -r -p "Apply service recovery now (start units / docker)? [Y/n]: " apply
if [[ "${apply,,}" =~ ^n(o)?$ ]]; then
  echo "Cancelled. No services changed."
else
  restore_flags=()
  if (( needs_db_restore )); then
    echo ""
    echo -e "${RED}Database looks empty or unhealthy.${NC}"
    echo "A recent non-empty sql.gz backup was found."
    echo -e "${YELLOW}Restore replaces the current oc4d database (a pre-restore snapshot is kept).${NC}"
    read -r -p "Restore latest usable backup now? [y/N]: " do_restore
    if [[ "${do_restore,,}" =~ ^y(es)?$ ]]; then
      restore_flags+=(--restore-db --yes)
    fi
  fi

  echo ""
  echo -e "${RED}Applying recovery…${NC}"
  run_sudo_recover --apply "${restore_flags[@]}"
  echo ""
  echo -e "${GREEN}Done.${NC}"
fi

echo ""
read -r -p "Press Enter to continue..."

if (( EMBEDDED )); then
  exit 0
fi
exec "$RETURN_TO"
