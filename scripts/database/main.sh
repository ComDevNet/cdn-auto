#!/bin/bash

cd "$(dirname "$(readlink -f "$0")")/../.." || exit 1

clear
echo ""
echo ""

pipe_lolcat() {
  if command -v lolcat >/dev/null 2>&1; then
    lolcat
  else
    cat
  fi
}

figlet -t -f 3d "DATABASE" | pipe_lolcat
echo ""
echo "=============================================================="
echo "  Backup and restore the OC4D PostgreSQL database"
echo "=============================================================="
echo ""

RED='\033[0;31m'
NC='\033[0m'
DARK_GRAY='\033[1;30m'
GREEN='\033[0;32m'

echo -e "1. Install auto backup ${DARK_GRAY}-| Every 6 hours, keep 3 backups${NC}"
echo -e "2. Run backup now      ${DARK_GRAY}-| Create a backup immediately${NC}"
echo -e "3. Restore database    ${DARK_GRAY}-| Recover from a saved backup${NC}"
echo -e "4. Status              ${DARK_GRAY}-| Timer status and backup list${NC}"
echo -e "${GREEN}5. Go Back             ${DARK_GRAY}-| Return to the main menu${NC}"
echo -e "${RED}6. Exit                ${DARK_GRAY}-| Exit CDN Auto${NC}"
echo ""

read -r -p "Choose an option (1-6): " choice

case "$choice" in
  1)
    sudo ./scripts/database/install.sh
    read -r -p "Press Enter to return to the menu..."
    exec ./scripts/database/main.sh
    ;;
  2)
    sudo ./scripts/database/backup.sh
    read -r -p "Press Enter to return to the menu..."
    exec ./scripts/database/main.sh
    ;;
  3)
    sudo ./scripts/database/restore.sh
    read -r -p "Press Enter to return to the menu..."
    exec ./scripts/database/main.sh
    ;;
  4)
    ./scripts/database/status.sh
    exec ./scripts/database/main.sh
    ;;
  5)
    exec ./main.sh
    ;;
  6)
    exec ./exit.sh
    ;;
  *)
    echo -e "${RED}Invalid choice.${NC}"
    sleep 1
    exec ./scripts/database/main.sh
    ;;
esac
