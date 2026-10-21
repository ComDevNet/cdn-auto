#!/bin/bash
set -euo pipefail
umask 077
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
cd "$PROJECT_ROOT"
source scripts/data/lib/resilience_helpers.sh
log() { echo "$*"; }
if ! background_memory_ready; then exit 0; fi
set -a
source config/automation.conf
set +a
[[ -n "${AWS_PROFILE:-}" ]] || unset AWS_PROFILE
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}" AWS_MAX_ATTEMPTS=3 AWS_RETRY_MODE=standard AWS_PAGER=
# Network reads happen outside the queue lock. Each deletion takes the lock briefly.
python3 scripts/data/automation/verify_s3_cleanup.py
