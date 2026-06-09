#!/bin/bash

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/data/lib/s3_picker_helpers.sh"

RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'

s3_bucket=$(awk -F= '/^s3_bucket=/{print $2}' scripts/data/upload/upload.sh | tr -d '"')

echo "Current s3_bucket: $s3_bucket"
read -p "Do you want to change the s3_bucket location? (y/n): " choice

if [[ $choice == "y" || $choice == "Y" ]]; then
  new_location=""
  if ! pick_s3_bucket_into new_location "$s3_bucket" "s3://"; then
    echo -e "${RED}Bucket selection cancelled.${NC}"
    sleep 1.5
    exec ./scripts/data/upload/main.sh
  fi

  sudo sed -i "s|^s3_bucket=.*|s3_bucket=\"$new_location\"|" scripts/data/upload/upload.sh
  echo -e "${GREEN}s3_bucket location updated to ${new_location}.${NC}"
  sleep 1.5
  exec ./scripts/data/upload/main.sh
fi

echo -e "${RED}s3_bucket location remains unchanged.${NC}"
sleep 1.5
exec ./scripts/data/upload/main.sh
