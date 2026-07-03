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

configure_modufetch_server() {
  local owner="${1:-${USER:-pi}}"
  local home_dir
  home_dir="$(eval echo "~${owner}")"
  local env_file="${home_dir}/modufetch/apps/pi-server/.env"
  local unit_file="/etc/systemd/system/modulefetch.service"
  local courses_table="oc4d-courses-table"
  local creds_file="${home_dir}/.aws/credentials"

  if [[ ! -f "$env_file" ]]; then
    echo "ModuFetch not found at ${home_dir}/modufetch — skipping ModuFetch setup."
    return 0
  fi

  # Placeholder keys in .env override ~/.aws/credentials and break DynamoDB/S3.
  sed -i '/^AWS_ACCESS_KEY_ID=your_/d;/^AWS_SECRET_ACCESS_KEY=your_/d' "$env_file"

  if grep -q '^DYNAMODB_COURSES_TABLE=' "$env_file"; then
    sed -i "s/^DYNAMODB_COURSES_TABLE=.*/DYNAMODB_COURSES_TABLE=${courses_table}/" "$env_file"
  else
    {
      echo ""
      echo "# OC4D course catalog in DynamoDB (ModuFetch Courses tab)"
      echo "DYNAMODB_COURSES_TABLE=${courses_table}"
    } >> "$env_file"
  fi

  for kv in \
    "AWS_REGION=us-east-1" \
    "AWS_SDK_LOAD_CONFIG=1" \
    "AWS_EC2_METADATA_DISABLED=true" \
    "AWS_SHARED_CREDENTIALS_FILE=${creds_file}"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "$env_file"; then
      sed -i "s|^${key}=.*|${kv}|" "$env_file"
    else
      echo "$kv" >> "$env_file"
    fi
  done

  echo "Configured ModuFetch DynamoDB table and AWS credential paths in ${env_file}"

  if [[ -f "$unit_file" ]]; then
    if ! grep -q 'AWS_SHARED_CREDENTIALS_FILE=' "$unit_file"; then
      sudo sed -i "/EnvironmentFile=.*pi-server\\/\\.env/a Environment=\"HOME=${home_dir}\"\nEnvironment=\"AWS_SHARED_CREDENTIALS_FILE=${creds_file}\"\nEnvironment=\"AWS_SDK_LOAD_CONFIG=1\"\nEnvironment=\"AWS_EC2_METADATA_DISABLED=true\"" "$unit_file"
      sudo systemctl daemon-reload
      echo "Updated ${unit_file} to use ${creds_file}"
    fi
    if systemctl is-enabled modulefetch.service &>/dev/null; then
      sudo systemctl restart modulefetch.service
      echo "Restarted modulefetch.service"
    fi
  fi
}
