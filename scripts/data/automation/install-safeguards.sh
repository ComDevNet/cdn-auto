#!/bin/bash
set -euo pipefail
[[ "$EUID" == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
install -d -o pi -g pi /home/pi/cdn-auto-backups
profile=default
if [[ -f "$PROJECT_ROOT/config/automation.conf" ]]; then
  profile="$(runuser -u pi -- bash -c 'source "$1"; printf "%s" "${AWS_PROFILE:-default}"' _ "$PROJECT_ROOT/config/automation.conf")"
fi
if command -v aws >/dev/null; then
  if [[ -f /home/pi/.aws/config ]]; then
    (umask 077; cp /home/pi/.aws/config "/home/pi/cdn-auto-backups/aws-config-before-safeguards-$(date +%Y%m%dT%H%M%S)")
  fi
  runuser -u pi -- aws configure set s3.max_bandwidth 1MB/s --profile "$profile"
  runuser -u pi -- aws configure set s3.max_concurrent_requests 2 --profile "$profile"
fi
cat > /etc/systemd/system/cdn-auto-s3-verified-cleanup.service <<EOF
[Unit]
Description=Background S3-verified cleanup without blocking uploads
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=pi
Group=pi
WorkingDirectory=$PROJECT_ROOT
ExecStart=/bin/bash $PROJECT_ROOT/scripts/data/automation/background-cleanup.sh
TimeoutStartSec=infinity
Nice=15
IOSchedulingClass=idle
CPUWeight=10
IOWeight=10
CPUQuota=20%
MemoryMax=256M
MemoryAccounting=yes
OOMScoreAdjust=500
StandardOutput=append:/home/pi/cdn-auto-backups/s3-cleanup-job.log
StandardError=append:/home/pi/cdn-auto-backups/s3-cleanup-job.log
EOF
cat > /etc/systemd/system/cdn-auto-s3-verified-cleanup.timer <<'EOF'
[Unit]
Description=Retry S3-verified local cleanup after boot and every six hours
[Timer]
OnBootSec=3min
OnUnitInactiveSec=6h
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now cdn-auto-s3-verified-cleanup.timer
