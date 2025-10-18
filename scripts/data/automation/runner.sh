#!/bin/bash

# This is the main automation engine. It handles collection, processing, and filtering.

# --- Configuration & Setup ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# The line below might cause an error if config.sh doesn't exist. We will create it next.
. "$PROJECT_ROOT/scripts/data/automation/config.sh" # Load configuration

TIMESTAMP=$(date +"%Y_%m_%d_%H%M%S")
# Use a generic folder name if DEVICE_NAME isn't set in config.sh
NEW_FOLDER="${DEVICE_NAME:-device}_logs_${TIMESTAMP}"
COLLECT_DIR="$PROJECT_ROOT/00_DATA/$NEW_FOLDER"

mkdir -p "$COLLECT_DIR"
echo "[INFO] Created collection folder: $COLLECT_DIR"

# --- STAGE 1: COLLECT LOGS ---
echo "[INFO] Starting log collection for SERVER_VERSION=${SERVER_VERSION}..."

case "$SERVER_VERSION" in
    v2|server\ v5|v5)
        # If a specific target is set by the collection menu, use only that.
        if [[ "$COLLECT_TARGET" == "oc4d" ]]; then
            LOG_DIRS=("/var/log/oc4d")
            echo "[INFO] Collection target set to OC4D."
        elif [[ "$COLLECT_TARGET" == "castle" ]]; then
            LOG_DIRS=("/var/log/castle") # Assuming this is the path
            echo "[INFO] Collection target set to Cape Coast Castle."
        elif [[ "$COLLECT_TARGET" == "dhub" ]]; then
            LOG_DIRS=("/var/log/dhub")
            echo "[INFO] Collection target set to D-Hub."
        else
            # Default behavior if COLLECT_TARGET isn't set
            LOG_DIRS=("/var/log/oc4d" "/var/log/dhub")
            echo "[INFO] No specific target. Collecting from all V2 sources."
        fi

        for log_dir in "${LOG_DIRS[@]}"; do
            if [ -d "$log_dir" ]; then
                echo "[INFO] Searching for logs in $log_dir..."
                # Find and copy all relevant log files into the collection directory
                find "$log_dir" -type f \( -name '*.log' -o -name '*.gz' \) -exec cp -v {} "$COLLECT_DIR"/ \;
            else
                echo "[WARN] Log directory not found: $log_dir"
            fi
        done
        ;;
    *)
        echo "[ERROR] Unknown SERVER_VERSION: $SERVER_VERSION. Aborting."
        exit 1
        ;;
esac

# --- STAGE 2: PROCESS LOGS ---

# If PYTHON_SCRIPT isn't set, infer it from COLLECT_TARGET.
if [ -z "$PYTHON_SCRIPT" ]; then
    if [ -n "$COLLECT_TARGET" ]; then
        echo "[INFO] PYTHON_SCRIPT not set. Inferring from COLLECT_TARGET: $COLLECT_TARGET"
        PYTHON_SCRIPT="$COLLECT_TARGET"
    fi
fi

echo "[INFO] Starting log processing with PYTHON_SCRIPT=${PYTHON_SCRIPT}..."
PROCESSOR_PATH="$PROJECT_ROOT/scripts/data/process/processors/${PYTHON_SCRIPT}.py"

if [ -f "$PROCESSOR_PATH" ]; then
    python3 "$PROCESSOR_PATH" "$NEW_FOLDER"
else
    echo "[ERROR] Processor script not found at $PROCESSOR_PATH. Aborting."
    exit 1
fi

echo "[SUCCESS] Automation cycle completed."
