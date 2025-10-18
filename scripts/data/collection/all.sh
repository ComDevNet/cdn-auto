#!/bin/bash

# --- Colors ---
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Get the project root directory to reliably call the runner script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
RUNNER_SCRIPT="$PROJECT_ROOT/scripts/data/automation/runner.sh"

# --- V2 Collection Menu ---
clear
echo ""
echo -e "${YELLOW}Choose a V2 Collection Source:${NC}"
echo "1. OC4D"
echo "2. Cape Coast Castle"
echo -e "${CYAN}3. D-Hub${NC}"
echo ""
read -p "Enter your choice (1-3): " choice

# --- Execute Runner Based on Choice ---
case "$choice" in
    1)
        echo "Selected OC4D. Starting runner..."
        export COLLECT_TARGET="oc4d"
        ;;
    2)
        echo "Selected Cape Coast Castle. Starting runner..."
        export COLLECT_TARGET="castle"
        ;;
    3)
        echo "Selected D-Hub. Starting runner..."
        export COLLECT_TARGET="dhub"
        ;;
    *)
        echo -e "${RED}Invalid choice. Aborting.${NC}"
        sleep 2
        exit 1
        ;;
esac

# All V2 collections use SERVER_VERSION="v5" as per the system's design
export SERVER_VERSION="v5"

echo "Executing the main automation runner..."
sleep 1

# Execute the main runner script with the chosen configuration
exec "$RUNNER_SCRIPT"
