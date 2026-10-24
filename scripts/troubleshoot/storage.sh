#!/usr/bin/env bash
# Storage troubleshoot menu: browse disk usage or repair upload-queue blowup.

clear
echo ""
echo ""

if command -v figlet >/dev/null 2>&1; then
  if command -v lolcat >/dev/null 2>&1; then
    figlet -t -f 3d "Storage" | lolcat
  else
    figlet -t -f 3d "Storage"
  fi
else
  echo "Storage"
fi

echo ""
echo "========================================"
echo "Disk usage and queue blowup repair"
echo "========================================"
echo ""

RED='\033[0;31m'
NC='\033[0m'
DARK_GRAY='\033[1;30m'
GREEN='\033[0;32m'

echo -e "1. Browse disk (ncdu)     ${DARK_GRAY}-| Interactive disk usage from /${NC}"
echo -e "2. Repair storage blowup  ${DARK_GRAY}-| Clear bloated upload-queue CSVs / logs (dry-run first)${NC}"
echo -e "3. Backfill missing S3 days ${DARK_GRAY}-| Local source-log days vs S3; re-export gaps${NC}"
echo -e "${GREEN}4. Go Back                ${DARK_GRAY}-| Troubleshoot menu${NC}"
echo -e "${RED}5. Exit                   ${DARK_GRAY}-| Exit CDN Auto${NC}"
echo -e "${NC}"

read -r -p "Choose an option (1-5): " choice

case "$choice" in
  1)
    if ! command -v ncdu >/dev/null 2>&1; then
      echo "Error: 'ncdu' not found. Install ncdu or use option 2 for queue repair."
      sleep 2
      exec ./scripts/troubleshoot/storage.sh
    fi
    echo "Running ncdu on / ..."
    ncdu /
    echo "returning to storage menu..."
    sleep 1
    exec ./scripts/troubleshoot/storage.sh
    ;;
  2)
    exec ./scripts/data/automation/repair_storage_blowup_menu.sh \
      --return ./scripts/troubleshoot/storage.sh
    ;;
  3)
    exec ./scripts/data/automation/backfill_s3_days_menu.sh \
      --return ./scripts/troubleshoot/storage.sh
    ;;
  4)
    exec ./scripts/troubleshoot/main.sh
    ;;
  5)
    exec ./exit.sh
    ;;
  *)
    echo "Invalid choice. Please choose 1-5."
    sleep 1.5
    exec ./scripts/troubleshoot/storage.sh
    ;;
esac
