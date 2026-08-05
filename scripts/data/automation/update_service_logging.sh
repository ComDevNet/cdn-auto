#!/bin/bash
# Install a robust wrapper that sends runner output to BOTH journal and file, and propagates exit codes.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRAPPER="/usr/local/bin/run_v5_log_processor.sh"
LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="$LOG_DIR/automation.log"
SERVICE="v5-log-processor.service"
TIMER="v5-log-processor.timer"

sudo mkdir -p "$LOG_DIR"
sudo touch "$LOG_FILE"
sudo chmod 644 "$LOG_FILE"

cat <<'WRAP' | sudo tee "$WRAPPER" >/dev/null
#!/bin/bash
set -euo pipefail
PROJECT_ROOT="__PROJECT_ROOT__"
LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="$LOG_DIR/automation.log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE" || true

cd "$PROJECT_ROOT"
echo "--- V5 Log Processor Automation triggered at $(date) ---" | tee -a "$LOG_FILE"
# Run runner and tee output to both journal and file; capture runner's exit code via PIPESTATUS.
set +e
bash -lc 'set -o pipefail; ./scripts/data/automation/runner.sh 2>&1 | tee -a "$LOG_FILE"'
rc=${PIPESTATUS[0]}
set -e
echo "--- V5 Automation run finished at $(date) (rc=$rc) ---" | tee -a "$LOG_FILE"
exit $rc
WRAP

sudo sed -i "s#__PROJECT_ROOT__#${PROJECT_ROOT//\//\\/}#g" "$WRAPPER"
sudo chmod +x "$WRAPPER"
sudo systemctl daemon-reload
sudo systemctl restart "$TIMER" || true
echo "Installed wrapper at $WRAPPER; timer restarted."
