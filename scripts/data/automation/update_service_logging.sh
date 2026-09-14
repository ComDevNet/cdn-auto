#!/bin/bash
# Install wrappers that send runner output to BOTH journal and file, and propagate exit codes.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="$LOG_DIR/automation.log"

install_wrapper() {
  local wrapper="$1"
  local mode="$2"
  local label="$3"
  cat <<WRAP | sudo tee "$wrapper" >/dev/null
#!/bin/bash
set -euo pipefail
PROJECT_ROOT="${PROJECT_ROOT}"
LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="\$LOG_DIR/automation.log"
LOCK_FILE="/home/pi/cdn-auto/00_DATA/00_UPLOAD_QUEUE/.automation.lock"

mkdir -p "\$LOG_DIR" "\$(dirname "\$LOCK_FILE")"
touch "\$LOG_FILE" || true

echo "--- ${label} triggered at \$(date) ---" | tee -a "\$LOG_FILE"
exec 9>"\$LOCK_FILE"
if ! flock -w 900 9; then
  echo "--- ${label} skipped at \$(date) (queue lock busy) ---" | tee -a "\$LOG_FILE"
  exit 0
fi

cd "\$PROJECT_ROOT"
find "\$PROJECT_ROOT/scripts" -name '*.sh' -exec sed -i 's/\\r\$//' {} + 2>/dev/null || true
set +e
bash -lc 'set -o pipefail; ./scripts/data/automation/runner.sh ${mode} 2>&1 | tee -a "\$LOG_FILE"'
rc=\${PIPESTATUS[0]}
set -e
echo "--- ${label} finished at \$(date) (rc=\$rc) ---" | tee -a "\$LOG_FILE"
exit \$rc
WRAP
  sudo chmod +x "$wrapper"
}

sudo mkdir -p "$LOG_DIR"
sudo touch "$LOG_FILE"
sudo chmod 644 "$LOG_FILE"

install_wrapper "/usr/local/bin/run_v5_log_harvester.sh" "harvest" "V5 Log Harvester"
install_wrapper "/usr/local/bin/run_v5_log_dispatcher.sh" "dispatch" "V5 Log Dispatcher"
install_wrapper "/usr/local/bin/run_v5_log_processor.sh" "all" "V5 Log Processor (all)"

sudo systemctl daemon-reload
sudo systemctl restart v5-log-harvester.timer 2>/dev/null || true
sudo systemctl restart v5-log-dispatcher.timer 2>/dev/null || true
echo "Installed harvest/dispatch/legacy wrappers; timers restarted if present."
