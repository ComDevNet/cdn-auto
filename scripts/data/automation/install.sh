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
echo "Installing V5 Log Processor Automation System"
echo "=============================================================="

echo ""

echo "🚀 Starting Automation Setup for the V5 Log Processor..."
echo "This will create a systemd service to run the process periodically."

echo ""

# --- Configuration ---
# The user that the service will run as.
# The script needs to have the correct permissions for this user.
SERVICE_USER="pi" 

# Name for the service and related files
SERVICE_NAME="v5-log-processor"

# The directory where the log file will be stored
LOG_DIR="/var/log/v5_log_processor"
LOG_FILE="$LOG_DIR/automation.log"

# Path for the wrapper script that systemd will execute
WRAPPER_SCRIPT_PATH="/usr/local/bin/run_v5_log_processor.sh"

# Determine the absolute path to the project's root directory
# This makes the script work no matter where it's cloned.
INSTALLER_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$INSTALLER_DIR/../../.." && pwd)
TARGET_SCRIPT="$PROJECT_ROOT/scripts/data/automation/runner.sh"

echo "📁 Project root directory: $PROJECT_ROOT"
echo "🎯 Target script: $TARGET_SCRIPT"
echo ""

# --- Stop and Remove Old Service if it Exists ---
echo "🔍 Checking for existing automation services..."
systemctl stop "$SERVICE_NAME.timer" 2>/dev/null || true
systemctl disable "$SERVICE_NAME.timer" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
rm -f "/etc/systemd/system/$SERVICE_NAME.timer"
rm -f "$WRAPPER_SCRIPT_PATH"
echo "✅ Old services cleaned up."
echo ""

# --- Create Wrapper Script ---
echo "📝 Creating executor script at $WRAPPER_SCRIPT_PATH..."
# This wrapper script ensures that the main script is run from the correct directory
tee "$WRAPPER_SCRIPT_PATH" > /dev/null << SCRIPT_EOF
#!/bin/bash
# This is a wrapper script for the systemd service.
# It changes to the correct project directory before running the script
# and redirects output to a dedicated log file.

echo "--- V5 Log Processor Automation triggered at \$(date) ---"

# Change to the project directory
cd "$PROJECT_ROOT"

# Execute the main data processing script (all.sh runs collect, process, upload)
# All output (stdout and stderr) is appended to the log file
./scripts/data/automation/runner.sh >> "$LOG_FILE" 2>&1

echo "--- V5 Automation run finished at \$(date) ---"
echo "" 
SCRIPT_EOF

# Make the wrapper script executable
chmod +x "$WRAPPER_SCRIPT_PATH"
echo "✅ Executor script created and made executable."
echo ""

# --- Create Log Directory and File ---
echo "📄 Setting up log file at $LOG_FILE..."
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chown -R "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
echo "✅ Log directory configured."
echo ""

# --- Create systemd Service File ---
echo "⚙️  Creating systemd service file..."
tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null << SERVICE_EOF
[Unit]
Description=Run the V5 log processor automation script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$WRAPPER_SCRIPT_PATH

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "✅ Service file created."
echo ""

# --- Create systemd Timer File ---
echo "⏰ Creating systemd timer file..."
# By default, the timer is set to run daily. This can be changed in the 'Configure' menu.
tee "/etc/systemd/system/$SERVICE_NAME.timer" > /dev/null << TIMER_EOF
[Unit]
Description=Run the V5 log processor automation script periodically
Requires=$SERVICE_NAME.service

[Timer]
OnBootSec=5min
OnCalendar=daily
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

echo "✅ Timer file created. Default schedule is set to run daily."
echo ""

# --- Enable and Start Services ---
echo "🔄 Reloading systemd, enabling and starting the timer..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME.timer"
systemctl start "$SERVICE_NAME.timer"

# Give a moment for the service to register
sleep 2

# --- Final Status Report ---
echo ""
echo "=============================================================="
echo "✅ V5 Log Processor Automation installed successfully!"
echo "=============================================================="
echo ""
echo "🎉 The V5 log processor will now run automatically on a daily schedule."
echo "📅 This schedule can be changed using the 'Configure Automation' option."
echo ""
echo "💡 Useful commands:"
echo "   📊 Check timer status:"
echo "      systemctl status $SERVICE_NAME.timer"
echo ""
echo "   📋 View automation logs:"
echo "      tail -f -n 50 $LOG_FILE"
echo ""
echo "   🚀 Trigger manual run:"
echo "      sudo $WRAPPER_SCRIPT_PATH"
echo ""
echo "   ⏹️  Stop automation:"
echo "      sudo systemctl stop $SERVICE_NAME.timer"
echo ""
echo "   ▶️  Start automation:"
echo "      sudo systemctl start $SERVICE_NAME.timer"
echo ""

# Check installation status automatically
echo "🔍 Verifying installation..."
sleep 1

# Check if services are running
if systemctl is-active --quiet "$SERVICE_NAME.timer"; then
    echo "✅ V5 Log Processor Timer: Active"
else
    echo "❌ V5 Log Processor Timer: Inactive"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME.timer"; then
    echo "✅ V5 Log Processor Timer: Enabled (will start on boot)"
else
    echo "❌ V5 Log Processor Timer: Disabled"
fi

# Check if wrapper script exists and is executable
if [ -x "$WRAPPER_SCRIPT_PATH" ]; then
    echo "✅ Wrapper script: Installed and executable"
else
    echo "❌ Wrapper script: Missing or not executable"
fi

# Check if log directory exists
if [ -d "$LOG_DIR" ]; then
    echo "✅ Log directory: Created and accessible"
else
    echo "❌ Log directory: Missing"
fi

echo ""
echo "🎯 Next step: Use 'Configure Automation' to customize your settings!"
echo ""

read -p "Press Enter to return to automation menu..."
exec ./scripts/data/automation/main.sh
