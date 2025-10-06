#!/bin/bash

clear
echo "=============================================================="
echo "  Select a folder to process"
echo "=============================================================="
echo ""

mapfile -t folders < <(find 00_DATA -mindepth 1 -maxdepth 1 -type d -name "*_logs_*" | sort -r)

if [ ${#folders[@]} -eq 0 ]; then
    echo "No collected log folders found in 00_DATA/."
    read -p "Press Enter to return..."
    exec ./scripts/data/main.sh
fi

PS3="Please enter the number of the folder to process: "
select FOLDER_PATH in "${folders[@]}"; do
    if [ -n "$FOLDER_PATH" ]; then
        FOLDER_NAME=$(basename "$FOLDER_PATH")
        echo "You selected folder: $FOLDER_NAME"
        break
    else
        echo "Invalid selection. Try again."
    fi
done

echo ""
echo "=============================================================="
echo "  Select the correct processor for these logs"
echo "=============================================================="
echo ""

PS3="Please enter the number of the processor to use: "
select PROCESSOR_CHOICE in "v4 (log.py)" "v5-OC4D (logv2.py)" "v5-Castle (castle.py)" "D-Hub (dhub.py)"; do
    case $PROCESSOR_CHOICE in
        "v4 (log.py)") PROCESSOR="scripts/data/process/processors/log.py"; break ;;
        "v5-OC4D (logv2.py)") PROCESSOR="scripts/data/process/processors/logv2.py"; break ;;
        "v5-Castle (castle.py)") PROCESSOR="scripts/data/process/processors/castle.py"; break ;;
        "D-Hub (dhub.py)") PROCESSOR="scripts/data/process/processors/dhub.py"; break ;;
        *) echo "Invalid selection. Please try again." ;;
    esac
done

echo "Running processor: $PROCESSOR on folder: $FOLDER_NAME"
python3 "$PROCESSOR" "$FOLDER_NAME"

echo -e "\nProcessing complete."
read -p "Press Enter to return to the menu..."
exec ./scripts/data/main.sh
