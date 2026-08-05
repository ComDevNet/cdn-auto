#!/bin/bash
# Shared chmod + OC4D backup directory setup for install/update.

ensure_oc4d_backup_dirs() {
  local owner="${1:-${SUDO_USER:-${USER:-pi}}}"
  sudo mkdir -p /var/backups/oc4d/database /var/log/oc4d-db-backup
  sudo chown -R "$owner:$owner" /var/backups/oc4d /var/log/oc4d-db-backup
  sudo chmod 700 /var/backups/oc4d /var/backups/oc4d/database
  sudo chmod 750 /var/log/oc4d-db-backup
  sudo touch /var/log/oc4d-db-backup/backup.log
  sudo chown "$owner:$owner" /var/log/oc4d-db-backup/backup.log
  sudo chmod 640 /var/log/oc4d-db-backup/backup.log
}

chmod_cdn_auto_scripts() {
  local root="${1:-.}"
  root="$(cd "$root" && pwd)"

  sudo chmod +x "$root"/*.sh
  sudo chmod +x "$root"/scripts/vpn/*.sh
  sudo chmod +x "$root"/scripts/update/*.sh
  sudo chmod +x "$root"/scripts/system/*.sh
  sudo chmod +x "$root"/scripts/system/networking/*.sh
  sudo chmod +x "$root"/scripts/data/*.sh
  sudo chmod +x "$root"/scripts/data/all/v1/*.sh
  sudo chmod +x "$root"/scripts/data/all/v1/process/*.sh
  sudo chmod +x "$root"/scripts/data/all/v2/*.sh
  sudo chmod +x "$root"/scripts/data/all/v2/process/*.sh
  sudo chmod +x "$root"/scripts/data/all/v3/*.sh
  sudo chmod +x "$root"/scripts/data/all/v3/process/*.sh
  sudo chmod +x "$root"/scripts/data/all/v4/*.sh
  sudo chmod +x "$root"/scripts/data/all/v4/process/*.sh
  sudo chmod +x "$root"/scripts/data/all/v5/*.sh
  sudo chmod +x "$root"/scripts/data/all/v5/process/*.sh
  sudo chmod +x "$root"/scripts/data/collection/*.sh
  sudo chmod +x "$root"/scripts/data/process/*.sh
  sudo chmod +x "$root"/scripts/data/upload/*.sh
  sudo chmod +x "$root"/scripts/troubleshoot/*.sh
  sudo chmod +x "$root"/scripts/data/automation/*.sh
  sudo chmod +x "$root"/scripts/database/*.sh
  sudo chmod +x "$root"/scripts/lib/*.sh
}
