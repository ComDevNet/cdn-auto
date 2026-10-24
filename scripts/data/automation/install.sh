#!/bin/bash

# This script must be run with sudo or as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ This script must be run with root privileges. Please use 'sudo'."
  exit 1
fi

# clear the screen
clear

echo ""
echo ""

# Function to safely pipe to lolcat if it exists, otherwise just cat
pipe_lolcat() {
  if command -v lolcat >/dev/null 2>&1; then
    lolcat
  else
    cat
  fi
}

# Display the name of the tool
figlet -t -f 3d "INSTALL" | pipe_lolcat

echo ""

# A border to cover the description and its centered
echo "=============================================================="
echo "Installing V5 Log Harvester + Dispatcher"
echo "=============================================================="

echo ""

echo "🚀 Starting Automation Setup..."
echo "This creates two systemd timers: harvest (frequent) and dispatch (upload window)."

echo ""

# --- Configuration ---
SERVICE_USER="pi"
HARVESTER_NAME="v5-log-harvester"
DISPATCHER_NAME="v5-log-dispatcher"
LEGACY_NAME="v5-log-processor"

LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="$LOG_DIR/automation.log"

HARVEST_WRAPPER="/usr/local/bin/run_v5_log_harvester.sh"
DISPATCH_WRAPPER="/usr/local/bin/run_v5_log_dispatcher.sh"
LEGACY_WRAPPER="/usr/local/bin/run_v5_log_processor.sh"

INSTALLER_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$INSTALLER_DIR/../../.." && pwd)

echo "📁 Project root directory: $PROJECT_ROOT"
echo ""

# --- Stop and Remove Old Services ---
echo "🔍 Checking for existing automation services..."
for name in "$LEGACY_NAME" "$HARVESTER_NAME" "$DISPATCHER_NAME"; do
  systemctl stop "$name.timer" 2>/dev/null || true
  systemctl disable "$name.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/$name.service"
  rm -f "/etc/systemd/system/$name.timer"
  rm -rf "/etc/systemd/system/$name.timer.d"
done
rm -f "$LEGACY_WRAPPER" "$HARVEST_WRAPPER" "$DISPATCH_WRAPPER"
echo "✅ Old services cleaned up."
echo ""

# --- Create Wrapper Scripts ---
echo "📝 Creating executor scripts..."
# Shared flock so harvest + dispatch never touch the queue at the same time.
LOCK_FILE="/home/pi/cdn-auto/00_DATA/00_UPLOAD_QUEUE/.automation.lock"

tee "$HARVEST_WRAPPER" > /dev/null << SCRIPT_EOF
#!/bin/bash
LOCK_FILE="$LOCK_FILE"
echo "--- V5 Log Harvester triggered at \$(date) ---"
mkdir -p "\$(dirname "\$LOCK_FILE")"
exec 9>"\$LOCK_FILE"
if ! flock -w 900 9; then
  echo "--- V5 Harvester skipped at \$(date) (queue lock busy) ---"
  exit 0
fi
cd "$PROJECT_ROOT"
find "$PROJECT_ROOT/scripts" -name '*.sh' -exec sed -i 's/\r\$//' {} + 2>/dev/null || true
./scripts/data/automation/runner.sh harvest >> "$LOG_FILE" 2>&1
echo "--- V5 Harvester finished at \$(date) ---"
echo ""
SCRIPT_EOF

tee "$DISPATCH_WRAPPER" > /dev/null << SCRIPT_EOF
#!/bin/bash
LOCK_FILE="$LOCK_FILE"
echo "--- V5 Log Dispatcher triggered at \$(date) ---"
mkdir -p "\$(dirname "\$LOCK_FILE")"
exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
  echo "--- V5 Dispatcher skipped at \$(date) (queue lock busy) ---"
  exit 0
fi
cd "$PROJECT_ROOT"
find "$PROJECT_ROOT/scripts" -name '*.sh' -exec sed -i 's/\r\$//' {} + 2>/dev/null || true
rc=0
./scripts/data/automation/runner.sh dispatch >> "$LOG_FILE" 2>&1 || rc=\$?
echo "--- V5 Dispatcher finished at \$(date) (status=\$rc) ---"
exit \$rc
SCRIPT_EOF

# Legacy alias: harvest then dispatch (manual escape hatch)
tee "$LEGACY_WRAPPER" > /dev/null << SCRIPT_EOF
#!/bin/bash
LOCK_FILE="$LOCK_FILE"
echo "--- V5 Log Processor (all) triggered at \$(date) ---"
mkdir -p "\$(dirname "\$LOCK_FILE")"
exec 9>"\$LOCK_FILE"
if ! flock -w 900 9; then
  echo "--- V5 Automation (all) skipped at \$(date) (queue lock busy) ---"
  exit 0
fi
cd "$PROJECT_ROOT"
find "$PROJECT_ROOT/scripts" -name '*.sh' -exec sed -i 's/\r\$//' {} + 2>/dev/null || true
./scripts/data/automation/runner.sh all >> "$LOG_FILE" 2>&1
echo "--- V5 Automation (all) finished at \$(date) ---"
echo ""
SCRIPT_EOF

chmod +x "$HARVEST_WRAPPER" "$DISPATCH_WRAPPER" "$LEGACY_WRAPPER"
echo "✅ Executor scripts created."
echo ""

# --- Create Log Directory and File ---
echo "📄 Setting up log file at $LOG_FILE..."
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chown -R "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
# Recover devices that already filled the disk with an unbounded automation.log.
if [[ -f "$LOG_FILE" ]]; then
  log_bytes="$(wc -c < "$LOG_FILE" | tr -d ' ')"
  if [[ "$log_bytes" =~ ^[0-9]+$ ]] && (( log_bytes > 52428800 )); then
    : > "$LOG_FILE"
    echo "⚠️  Truncated oversized automation.log ($(numfmt --to=iec "$log_bytes" 2>/dev/null || echo "${log_bytes}B"))."
  fi
fi
mkdir -p /etc/logrotate.d
cat > /etc/logrotate.d/oc4d-v5-automation << ROTATE_EOF
$LOG_FILE /home/pi/cdn-auto-backups/s3-cleanup-job.log {
    daily
    maxsize 25M
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
    su $SERVICE_USER $SERVICE_USER
}
ROTATE_EOF
echo "✅ Log directory configured."
echo ""

# --- Harvester unit ---
echo "⚙️  Creating harvester systemd units..."
tee "/etc/systemd/system/$HARVESTER_NAME.service" > /dev/null << SERVICE_EOF
[Unit]
Description=CDN-auto harvest (collect/process/enqueue; no upload)
After=local-fs.target

[Service]
Type=oneshot
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$HARVEST_WRAPPER
Nice=10
IOSchedulingClass=idle
CPUWeight=10
IOWeight=10
CPUQuota=50%
MemoryHigh=512M
MemoryMax=768M
OOMScoreAdjust=500
OOMPolicy=kill
MemoryAccounting=yes
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
SERVICE_EOF

tee "/etc/systemd/system/$HARVESTER_NAME.timer" > /dev/null << TIMER_EOF
[Unit]
Description=Run CDN-auto harvest periodically while device is on
Requires=$HARVESTER_NAME.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

# --- Dispatcher unit ---
echo "⚙️  Creating dispatcher systemd units..."
tee "/etc/systemd/system/$DISPATCHER_NAME.service" > /dev/null << SERVICE_EOF
[Unit]
Description=CDN-auto dispatch (upload pending queue when window open)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$DISPATCH_WRAPPER
Nice=10
IOSchedulingClass=idle
CPUWeight=10
IOWeight=10
CPUQuota=50%
MemoryHigh=192M
MemoryMax=384M
OOMScoreAdjust=500
OOMPolicy=kill
MemoryAccounting=yes
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
SERVICE_EOF

tee "/etc/systemd/system/$DISPATCHER_NAME.timer" > /dev/null << TIMER_EOF
[Unit]
Description=Check CDN-auto upload window and flush pending queue
Requires=$DISPATCHER_NAME.service

[Timer]
OnBootSec=5min
OnUnitInactiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

echo "✅ Service/timer files created."
echo ""

# --- Optional repair (never automatic deletes) ---
# Install only truncates a huge automation.log + installs logrotate.
# Bloated queue CSVs require an explicit menu/install prompt.
REPAIR_SCRIPT="$PROJECT_ROOT/scripts/data/automation/repair_storage_blowup.sh"
REPAIR_MENU="$PROJECT_ROOT/scripts/data/automation/repair_storage_blowup_menu.sh"
if [[ -f "$REPAIR_SCRIPT" ]] && [[ "${NONINTERACTIVE:-}" != "1" ]] && [[ -t 0 ]]; then
  chmod +x "$REPAIR_SCRIPT" "$REPAIR_MENU" 2>/dev/null || true
  echo "🔍 Checking for storage-blowup symptoms (oversized queue CSVs / orphan temps)..."
  if bash "$REPAIR_SCRIPT" --detect; then
    echo ""
    echo "⚠️  This device looks affected by the old near-realtime CSV re-import bug."
    echo "   Install will NOT delete queue files automatically."
    echo "   You can repair now (dry-run → confirm), or later via:"
    echo "   Troubleshoot → Storage → Repair storage blowup"
    echo "   Data → Automation → Repair Storage Blowup"
    echo ""
    read -r -p "Run interactive repair now before starting timers? [y/N]: " do_repair
    if [[ "${do_repair,,}" =~ ^y(es)?$ ]]; then
      bash "$REPAIR_MENU" --embedded || true
      echo ""
    else
      echo "Skipping repair. Start harvest only after freeing disk if usage is still critical."
      echo ""
    fi
  else
    echo "✅ No storage-blowup symptoms detected."
    echo ""
  fi
fi

# --- Enable and Start ---
echo "🔄 Reloading systemd, enabling and starting timers..."
systemctl daemon-reload
systemctl enable "$HARVESTER_NAME.timer" "$DISPATCHER_NAME.timer"
systemctl start "$HARVESTER_NAME.timer" "$DISPATCHER_NAME.timer"
bash "$PROJECT_ROOT/scripts/data/automation/install-safeguards.sh" || exit $?
sleep 2

echo ""
echo "=============================================================="
echo "✅ Harvester + Dispatcher installed successfully!"
echo "=============================================================="
echo ""
echo "🌾 Harvester: every hour while the device is on (override via Configure)."
echo "📤 Dispatcher: checks every minute after each attempt; uploads only inside UPLOAD_WINDOW."
echo ""
echo "💡 Useful commands:"
echo "   systemctl status $HARVESTER_NAME.timer $DISPATCHER_NAME.timer"
echo "   tail -f -n 50 $LOG_FILE"
echo "   sudo $HARVEST_WRAPPER"
echo "   sudo $DISPATCH_WRAPPER"
echo "   sudo $LEGACY_WRAPPER   # harvest then dispatch"
echo ""

if systemctl is-active --quiet "$HARVESTER_NAME.timer"; then
    echo "✅ Harvester Timer: Active"
else
    echo "❌ Harvester Timer: Inactive"
fi
if systemctl is-active --quiet "$DISPATCHER_NAME.timer"; then
    echo "✅ Dispatcher Timer: Active"
else
    echo "❌ Dispatcher Timer: Inactive"
fi

echo ""
echo "🎯 Next step: Use 'Configure Automation' to set harvest interval + upload window."
echo ""

# Non-interactive installs (migrate_near_realtime / CI) skip the menu handoff.
if [[ "${NONINTERACTIVE:-}" == "1" ]] || [[ ! -t 0 ]]; then
  exit 0
fi

read -p "Press Enter to return to automation menu..."
exec ./scripts/data/automation/main.sh
