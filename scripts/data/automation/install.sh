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
if ! flock -w 900 9; then
  echo "--- V5 Dispatcher skipped at \$(date) (queue lock busy) ---"
  exit 0
fi
cd "$PROJECT_ROOT"
find "$PROJECT_ROOT/scripts" -name '*.sh' -exec sed -i 's/\r\$//' {} + 2>/dev/null || true
./scripts/data/automation/runner.sh dispatch >> "$LOG_FILE" 2>&1
echo "--- V5 Dispatcher finished at \$(date) ---"
echo ""
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

[Install]
WantedBy=multi-user.target
SERVICE_EOF

tee "/etc/systemd/system/$DISPATCHER_NAME.timer" > /dev/null << TIMER_EOF
[Unit]
Description=Check CDN-auto upload window and flush pending queue
Requires=$DISPATCHER_NAME.service

[Timer]
OnBootSec=5min
OnCalendar=hourly
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

echo "✅ Service/timer files created."
echo ""

# --- Enable and Start ---
echo "🔄 Reloading systemd, enabling and starting timers..."
systemctl daemon-reload
systemctl enable "$HARVESTER_NAME.timer" "$DISPATCHER_NAME.timer"
systemctl start "$HARVESTER_NAME.timer" "$DISPATCHER_NAME.timer"
sleep 2

echo ""
echo "=============================================================="
echo "✅ Harvester + Dispatcher installed successfully!"
echo "=============================================================="
echo ""
echo "🌾 Harvester: every hour while the device is on (override via Configure)."
echo "📤 Dispatcher: hourly check; uploads only inside UPLOAD_WINDOW."
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
