#!/bin/bash
# cdn-auto configure (defaults-first; no region flags; SSE fallback; fixed temp-file perms)
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/automation.conf"
mkdir -p "$CONFIG_DIR"

SERVICE_UNIT="/etc/systemd/system/v5-log-processor.service"
SERVICE_USER="$(awk -F= '/^User=/{print $2}' "$SERVICE_UNIT" 2>/dev/null | tail -n1)"
[ -z "${SERVICE_USER:-}" ] && SERVICE_USER="${SUDO_USER:-pi}"
SERVICE_GROUP="$SERVICE_USER"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
say(){ echo "[$(ts)] $*"; }
have(){ command -v "$1" >/dev/null 2>/dev/null; }
have_whiptail(){ have whiptail; }

confirm(){
  local msg="$1"
  if have_whiptail; then whiptail --yesno "$msg" 10 74
  else read -rp "$msg [y/N]: " yn; [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
  fi
}

confirm_default(){
  local msg="$1" default="${2:-no}" yn prompt
  default="${default,,}"
  if have_whiptail; then
    if [[ "$default" == "yes" || "$default" == "y" || "$default" == "1" || "$default" == "true" ]]; then
      whiptail --yesno "$msg" 10 74
    else
      whiptail --defaultno --yesno "$msg" 10 74
    fi
  else
    if [[ "$default" == "yes" || "$default" == "y" || "$default" == "1" || "$default" == "true" ]]; then
      prompt="[Y/n]"
    else
      prompt="[y/N]"
    fi
    read -rp "$msg $prompt: " yn
    yn="${yn:-$default}"
    [[ "${yn,,}" == "y" || "${yn,,}" == "yes" || "${yn,,}" == "1" || "${yn,,}" == "true" ]]
  fi
}

prompt_text(){
  local title="$1" default="$2" outvar="$3" val
  if have_whiptail; then
    val="$(whiptail --inputbox "$title" 10 74 "$default" 3>&1 1>&2 2>&3 || true)"
  else
    read -rp "$title [$default]: " val; val="${val:-$default}"
  fi
  printf -v "$outvar" '%s' "$val"
}

menu_select(){
  if have_whiptail; then
    whiptail --nocancel --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" ); local n=$(( ${#options[@]} / 2 ))
    echo "$title"
    for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done
    local c; while :; do read -rp "Choose [1-$n]: " c; [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )) && { echo "${options[$(((c-1)*2))]}"; return 0; }; echo "Invalid choice."; done
  fi
}

menu_select_cancelable(){
  if have_whiptail; then
    local choice
    choice="$(whiptail --cancel-button "Exit" --ok-button "Select" --notags --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3)" || { echo "__EXIT__"; return 0; }
    echo "$choice"
  else
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" ); local n=$(( ${#options[@]} / 2 ))
    echo "$title"; for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done; echo " x) Exit"
    local c; while :; do read -rp "Choose [1-$n or x]: " c; [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )) && { echo "${options[$(((c-1)*2))]}"; return 0; }; [[ "$c" =~ ^[xX]$ ]] && { echo "__EXIT__"; return 0; }; echo "Invalid choice."; done
  fi
}

validate_device_location(){ [[ "$1" =~ ^[A-Za-z0-9_-]{2,64}$ ]]; }
sanitize_subfolder(){ local sf="${1#/}"; sf="${sf%/}"; echo "$sf"; }

aws_su(){
  if [[ -n "${SUDO_USER:-}" && "$SERVICE_USER" != "$USER" ]]; then sudo -u "$SERVICE_USER" aws "$@"
  else aws "$@"
  fi
}
aws_capture(){ aws_su "$@" 2>/dev/null; }

child_prefix_from_s3_value(){
  local parent="${1#/}"
  local value="$2"

  parent="${parent%/}"
  [[ -n "$parent" ]] && parent="${parent}/"
  value="${value//$'\r'/}"
  value="${value#/}"

  if [[ -n "$parent" && "$value" == "$parent"* ]]; then
    value="${value#"$parent"}"
  fi

  value="${value#/}"
  value="${value%/}"
  value="${value%%/*}"
  [[ -n "$value" ]] && printf '%s\n' "$value"
}

discover_child_prefixes(){
  local bucket_name="$1"
  local parent_prefix="${2#/}"
  local scan_contents="${3:-0}"
  local prefix_args=()
  local out rc line p s3_uri base

  parent_prefix="${parent_prefix%/}"
  [[ -n "$parent_prefix" ]] && prefix_args=( --prefix "${parent_prefix}/" )

  out="$(aws_capture s3api list-objects-v2 --bucket "$bucket_name" "${prefix_args[@]}" --delimiter '/' --query 'CommonPrefixes[].Prefix' --output text 2>&1)"; rc=$?
  if (( rc == 0 )) && [[ -n "$out" && "$out" != "None" ]]; then
    while IFS= read -r p; do
      child_prefix_from_s3_value "$parent_prefix" "$p"
    done < <(printf '%s' "$out" | tr '\t' '\n' | sed '/^[[:space:]]*$/d')
  fi

  s3_uri="s3://$bucket_name/"
  [[ -n "$parent_prefix" ]] && s3_uri="${s3_uri}${parent_prefix}/"
  out="$(aws_capture s3 ls "$s3_uri" 2>&1 || true)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*PRE[[:space:]]+(.+)/[[:space:]]*$ ]]; then
      child_prefix_from_s3_value "" "${BASH_REMATCH[1]}"
    fi
  done <<< "$out"

  # Some S3 "folders" only show up as object keys beneath the prefix. Scanning
  # keys under RACHEL recovers those without treating root-level CSVs as folders.
  if [[ "$scan_contents" == "1" ]]; then
    out="$(aws_capture s3api list-objects-v2 --bucket "$bucket_name" "${prefix_args[@]}" --query 'Contents[].Key' --output text 2>&1)"; rc=$?
    if (( rc == 0 )) && [[ -n "$out" && "$out" != "None" ]]; then
      base="$parent_prefix"
      [[ -n "$base" ]] && base="${base}/"
      while IFS= read -r p; do
        p="${p//$'\r'/}"
        [[ -n "$base" && "$p" != "$base"* ]] && continue
        p="${p#"$base"}"
        [[ "$p" != */* ]] && continue
        child_prefix_from_s3_value "" "$p"
      done < <(printf '%s' "$out" | tr '\t' '\n' | sed '/^[[:space:]]*$/d')
    fi
  fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/s3_picker_helpers.sh"

check_network(){
  getent hosts s3.amazonaws.com >/dev/null 2>&1 || return 1
  have curl && timeout 5s curl -Is https://s3.amazonaws.com >/dev/null 2>&1 || true
  return 0
}
check_aws_identity(){
  aws_su sts get-caller-identity --output text >/dev/null 2>&1 && { say "✅ AWS identity OK for '$SERVICE_USER'."; return 0; }
  say "⚠️  AWS identity not confirmed for '$SERVICE_USER' (continuing allowed)."; return 1
}
ensure_preflight_ok(){
  local net_ok=0 id_ok=0
  check_network && net_ok=1 || net_ok=0
  check_aws_identity && id_ok=1 || id_ok=0
  (( net_ok==1 && id_ok==1 )) && return 0
  local msg=""
  (( net_ok==0 )) && msg+="• Network to s3.amazonaws.com unreachable.\n"
  (( id_ok==0 )) && msg+="• AWS identity not confirmed for '$SERVICE_USER'.\n"
  msg+="\nContinue anyway? (S3 bucket/prefix choices come from AWS discovery.)"
  if have_whiptail; then whiptail --title "Preflight checks" --yes-button "Continue" --no-button "Exit" --yesno "$msg" 14 74 || exit 2
  else echo -e "$msg"; read -rp "Continue? [Y/n]: " yn; [[ "${yn,,}" == "n" ]] && exit 2
  fi
}

# Load existing config if present
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || true

SERVER_VERSION="${SERVER_VERSION:-v2}"
DEVICE_LOCATION="${DEVICE_LOCATION:-device}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-oc4d}"
S3_BUCKET="${S3_BUCKET:-s3://example-bucket}"
S3_SUBFOLDER="${S3_SUBFOLDER:-}"
RACHEL_SUBFOLDER="${RACHEL_SUBFOLDER:-}"
SCHEDULE_TYPE="${SCHEDULE_TYPE:-daily}"
RUN_INTERVAL="${RUN_INTERVAL:-86400}"
KOLIBRI_FACILITY_ID="${KOLIBRI_FACILITY_ID:-}"
MODULEGAZE_ENABLED="${MODULEGAZE_ENABLED:-1}"
MODULEGAZE_API_BASE_URL="${MODULEGAZE_API_BASE_URL:-http://127.0.0.1:3002}"
MODULEGAZE_MODULE_MAP_FILE="${MODULEGAZE_MODULE_MAP_FILE:-$PROJECT_ROOT/config/oc4d/module-map.csv}"
OC4D_ASSESSMENTS_ENABLED="${OC4D_ASSESSMENTS_ENABLED:-0}"
OC4D_API_BASE_URL="${OC4D_API_BASE_URL:-http://127.0.0.1:3000}"
OC4D_API_TOKEN="${OC4D_API_TOKEN:-}"
OC4D_BUCKET="${OC4D_BUCKET:-oc4d-raw-reports}"
OC4D_PARENT_ORG="${OC4D_PARENT_ORG:-Home-Schooling}"
OC4D_UPLOAD_MODE="${OC4D_UPLOAD_MODE:-direct_s3}"
OC4D_SOURCE_DIR="${OC4D_SOURCE_DIR:-}"
OC4D_STUDENT_MAP_FILE="${OC4D_STUDENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/student-map.csv}"
OC4D_ASSESSMENT_MAP_FILE="${OC4D_ASSESSMENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/assessment-map.csv}"
OC4D_STATE_FILE="${OC4D_STATE_FILE:-$PROJECT_ROOT/00_DATA/00_OC4D_ASSESSMENTS/uploaded-state.json}"
OC4D_UNASSIGNED_STUDENT_ID="${OC4D_UNASSIGNED_STUDENT_ID:-unassigned}"
OC4D_STUDENT_PREFIX_SYNC="${OC4D_STUDENT_PREFIX_SYNC:-1}"
OC4D_CLOUD_STUDENT_MAP_FILE="${OC4D_CLOUD_STUDENT_MAP_FILE:-}"
OC4D_CLOUD_STUDENT_MAP_S3_URI="${OC4D_CLOUD_STUDENT_MAP_S3_URI:-}"
OC4D_CLOUD_STUDENT_MAP_URL="${OC4D_CLOUD_STUDENT_MAP_URL:-}"
OC4D_CLOUD_STUDENTS_API_BASE_URL="${OC4D_CLOUD_STUDENTS_API_BASE_URL:-}"
OC4D_CLOUD_API_TOKEN="${OC4D_CLOUD_API_TOKEN:-}"

ensure_preflight_ok || true

# --- menus
sel=$(menu_select "Select server version" 15 74 7 \
  v4 "Server v4 (Apache / access.log*)" \
  v5 "Server v5 (OC4D or Cape Coast Castle)" \
  v6 "Server v6 (OC4D with module paths)" \
  dhub "D-Hub (UUID-based module logs)" \
)
case "$sel" in
  v4) SERVER_VERSION="v1" ;;
  v5) SERVER_VERSION="v2" ;;
  v6) SERVER_VERSION="v6" ;;
  dhub) SERVER_VERSION="v3" ;;
esac

if [[ "$SERVER_VERSION" == "v2" ]]; then
  PYTHON_SCRIPT=$(menu_select "Select logs flavor (v2)" 12 74 5 \
    oc4d "OC4D logs (logv2.py)" \
    cape_coast_d "Cape Coast Castle logs (castle.py)" \
  )
else
  PYTHON_SCRIPT="oc4d"
fi

# If user selected a non-castle log type, and hourly was previously configured,
# gracefully downgrade to daily to prevent an invalid configuration.
if [[ "$PYTHON_SCRIPT" != "cape_coast_d" && "$SCHEDULE_TYPE" == "hourly" ]]; then
  say "⚠️ Hourly schedule is only for Cape Coast Castle logs. Downgrading to daily."
  SCHEDULE_TYPE="daily"
fi

if confirm_default "Also collect/process/upload ModuleGaze logs when /var/log/modulegaze exists?" "$MODULEGAZE_ENABLED"; then
  MODULEGAZE_ENABLED="1"
else
  MODULEGAZE_ENABLED="0"
fi

pick_oc4d_bucket() {
  pick_s3_bucket_into OC4D_BUCKET "${OC4D_BUCKET}" "" || exit 2
}

pick_oc4d_parent_org() {
  local bucket_name
  bucket_name="$(s3_picker_bucket_name "$OC4D_BUCKET")"
  pick_s3_prefix_into OC4D_PARENT_ORG "s3://${bucket_name}" "" 0 "${OC4D_PARENT_ORG}" \
    "Select OC4D parent org in s3://${bucket_name}/" 0 || exit 2
}

if [[ "$SERVER_VERSION" == "v2" || "$SERVER_VERSION" == "v6" ]]; then
  if confirm_default "Also pull OC4D assessment results from the local OC4D API and upload to the OC4D reports bucket?" "$OC4D_ASSESSMENTS_ENABLED"; then
    OC4D_ASSESSMENTS_ENABLED="1"
    OC4D_API_BASE_URL="http://127.0.0.1:3000"
    OC4D_API_TOKEN=""
    OC4D_STUDENT_MAP_FILE="${OC4D_STUDENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/student-map.csv}"
    OC4D_ASSESSMENT_MAP_FILE="${OC4D_ASSESSMENT_MAP_FILE:-$PROJECT_ROOT/config/oc4d/assessment-map.csv}"
    OC4D_SOURCE_DIR=""
    OC4D_UPLOAD_MODE="direct_s3"
    say "OC4D API: ${OC4D_API_BASE_URL} (local; token auto-fetched at runtime)"
    say "OC4D maps: ${OC4D_STUDENT_MAP_FILE} and ${OC4D_ASSESSMENT_MAP_FILE}"
    say "OC4D unmapped students upload to: ${OC4D_UNASSIGNED_STUDENT_ID} (assign in cloud /admin/students)"
    pick_oc4d_bucket
    pick_oc4d_parent_org
  else
    OC4D_ASSESSMENTS_ENABLED="0"
  fi
else
  OC4D_ASSESSMENTS_ENABLED="0"
fi

while :; do
  prompt_text "Device location (letters/numbers/_/-)" "${DEVICE_LOCATION}" DEVICE_LOCATION
  validate_device_location "$DEVICE_LOCATION" && break || say "Invalid location. Use 2-64 chars: [A-Za-z0-9_-]"
done

pick_bucket() {
  pick_s3_bucket_into S3_BUCKET "${S3_BUCKET}" "s3://" || exit 2
}
pick_bucket

pick_subfolder() {
  local bucket_name
  bucket_name="$(s3_picker_bucket_name "$S3_BUCKET")"
  pick_s3_prefix_into S3_SUBFOLDER "$S3_BUCKET" "" 1 "${S3_SUBFOLDER}" \
    "Select S3 subfolder in s3://${bucket_name}/" 0 || exit 2
}
pick_subfolder
S3_SUBFOLDER="$(sanitize_subfolder "$S3_SUBFOLDER")"

pick_rachel_subfolder() {
  local bucket_name rachel_base
  bucket_name="$(s3_picker_bucket_name "$S3_BUCKET")"
  rachel_base="${S3_SUBFOLDER:+${S3_SUBFOLDER}/}RACHEL"
  pick_s3_prefix_into RACHEL_SUBFOLDER "$S3_BUCKET" "$rachel_base" 1 "${RACHEL_SUBFOLDER}" \
    "Select RACHEL subfolder in s3://${bucket_name}/${rachel_base}/" 1 || exit 2
}
pick_rachel_subfolder
RACHEL_SUBFOLDER="$(sanitize_subfolder "$RACHEL_SUBFOLDER")"

# --- Dynamic Schedule Menu ---
sched_opts=(
  daily   "Once per day"
  weekly  "Once per week"
  monthly "Once per month"
  yearly  "Once per year"
  custom  "Custom interval (seconds)"
)
# If castle is selected, add hourly to the beginning of the options
if [[ "$PYTHON_SCRIPT" == "cape_coast_d" ]]; then
  sched_opts=( hourly "Every hour" "${sched_opts[@]}" )
fi
sched=$(menu_select "Choose schedule" 15 74 7 "${sched_opts[@]}")

case "$sched" in
  hourly)  SCHEDULE_TYPE="hourly";  RUN_INTERVAL="3600" ;;
  daily)   SCHEDULE_TYPE="daily";   RUN_INTERVAL="86400" ;;
  weekly)  SCHEDULE_TYPE="weekly";  RUN_INTERVAL="604800" ;;
  monthly) SCHEDULE_TYPE="monthly"; RUN_INTERVAL="2592000" ;;
  yearly)  SCHEDULE_TYPE="yearly";  RUN_INTERVAL="31536000" ;;
  custom)  SCHEDULE_TYPE="custom"; while :; do prompt_text "Custom interval in seconds (>=300)" "${RUN_INTERVAL}" RUN_INTERVAL; [[ "$RUN_INTERVAL" =~ ^[0-9]+$ ]] && (( RUN_INTERVAL >= 300 )) && break || say "Enter a number >= 300."; done ;;
esac

summary=$(cat <<EOF
Service user   : $SERVICE_USER
Server version : $SERVER_VERSION
Logs flavor    : $PYTHON_SCRIPT
Device location: $DEVICE_LOCATION
S3 bucket      : $S3_BUCKET
S3 subfolder   : ${S3_SUBFOLDER:-<root>}
RACHEL subfolder: ${RACHEL_SUBFOLDER:-<RACHEL root>}
Schedule       : $SCHEDULE_TYPE (interval=${RUN_INTERVAL}s)
Kolibri facility: ${KOLIBRI_FACILITY_ID:-<default facility>}
ModuleGaze     : $([[ "$MODULEGAZE_ENABLED" == "1" ]] && echo enabled || echo disabled)
ModuleGaze API : ${MODULEGAZE_API_BASE_URL:-http://127.0.0.1:3002}
OC4D assessments: $([[ "$OC4D_ASSESSMENTS_ENABLED" == "1" ]] && echo enabled || echo disabled)
OC4D API       : ${OC4D_API_BASE_URL:-http://127.0.0.1:3000} (auto-auth)
OC4D bucket    : ${OC4D_BUCKET:-oc4d-raw-reports}
OC4D parentOrg : ${OC4D_PARENT_ORG:-Home-Schooling}
Config file    : $CONFIG_FILE
EOF
)
if have_whiptail; then whiptail --title "Confirm configuration" --msgbox "$summary" 19 74; else echo; echo "$summary"; echo; fi
confirm "Save configuration?" || { echo "Aborted."; exit 1; }

umask 077
tmp="${CONFIG_FILE}.tmp"
cat > "$tmp" <<EOF
# cdn-auto automation config (kept INSIDE the repo)
SERVER_VERSION="$SERVER_VERSION"
DEVICE_LOCATION="$DEVICE_LOCATION"
PYTHON_SCRIPT="$PYTHON_SCRIPT"
S3_BUCKET="$S3_BUCKET"
S3_SUBFOLDER="$S3_SUBFOLDER"
RACHEL_SUBFOLDER="$RACHEL_SUBFOLDER"
SCHEDULE_TYPE="$SCHEDULE_TYPE"
RUN_INTERVAL="$RUN_INTERVAL"
KOLIBRI_FACILITY_ID="$KOLIBRI_FACILITY_ID"
MODULEGAZE_ENABLED="$MODULEGAZE_ENABLED"
MODULEGAZE_API_BASE_URL="$MODULEGAZE_API_BASE_URL"
MODULEGAZE_MODULE_MAP_FILE="$MODULEGAZE_MODULE_MAP_FILE"
OC4D_ASSESSMENTS_ENABLED="$OC4D_ASSESSMENTS_ENABLED"
OC4D_API_BASE_URL="$OC4D_API_BASE_URL"
OC4D_API_TOKEN="$OC4D_API_TOKEN"
OC4D_BUCKET="$OC4D_BUCKET"
OC4D_PARENT_ORG="$OC4D_PARENT_ORG"
OC4D_UPLOAD_MODE="$OC4D_UPLOAD_MODE"
OC4D_SOURCE_DIR="$OC4D_SOURCE_DIR"
OC4D_STUDENT_MAP_FILE="$OC4D_STUDENT_MAP_FILE"
OC4D_ASSESSMENT_MAP_FILE="$OC4D_ASSESSMENT_MAP_FILE"
OC4D_STATE_FILE="$OC4D_STATE_FILE"
OC4D_UNASSIGNED_STUDENT_ID="$OC4D_UNASSIGNED_STUDENT_ID"
OC4D_STUDENT_PREFIX_SYNC="$OC4D_STUDENT_PREFIX_SYNC"
OC4D_CLOUD_STUDENT_MAP_FILE="$OC4D_CLOUD_STUDENT_MAP_FILE"
OC4D_CLOUD_STUDENT_MAP_S3_URI="$OC4D_CLOUD_STUDENT_MAP_S3_URI"
OC4D_CLOUD_STUDENT_MAP_URL="$OC4D_CLOUD_STUDENT_MAP_URL"
OC4D_CLOUD_STUDENTS_API_BASE_URL="$OC4D_CLOUD_STUDENTS_API_BASE_URL"
OC4D_CLOUD_API_TOKEN="$OC4D_CLOUD_API_TOKEN"
EOF
mv -f "$tmp" "$CONFIG_FILE"
sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "$CONFIG_FILE"
sudo chmod 600 "$CONFIG_FILE"
say "💾 Saved: $CONFIG_FILE (owner: $SERVICE_USER)"

# ---------- robust live test (NO region flags) ----------
test_upload(){
  local bucket="${S3_BUCKET#s3://}"; bucket="${bucket%%/*}"
  local tsf="$(date +%Y%m%d_%H%M%S)"
  local key="${S3_SUBFOLDER:+$S3_SUBFOLDER/}RACHEL/_config_test_${tsf}.txt"

  # create test body as the SERVICE_USER so aws (run as pi) can read it
  local tmpfile
  if sudo -u "$SERVICE_USER" command -v mktemp >/dev/null 2>&1; then
    tmpfile="$(sudo -u "$SERVICE_USER" mktemp /tmp/cdn_auto_cfgtest.XXXXXX)"
    sudo -u "$SERVICE_USER" sh -c "printf 'cdn-auto test %s\n' '$tsf' > '$tmpfile'"
  else
    tmpfile="$(mktemp /tmp/cdn_auto_cfgtest.XXXXXX)"
    printf 'cdn-auto test %s\n' "$tsf" > "$tmpfile"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$tmpfile" 2>/dev/null || true
    chmod 600 "$tmpfile" 2>/dev/null || true
  fi
  # When the function returns, remove the temp file AND unset the script-wide EXIT trap.
  trap 'rm -f "$tmpfile" 2>/dev/null; trap - EXIT' RETURN
  # If the script exits unexpectedly while this function is running, clean up the temp file.
  trap 'rm -f "$tmpfile" 2>/dev/null' EXIT

  say "▶ Test upload → s3://$bucket/$key"
  if aws_su s3api put-object --bucket "$bucket" --key "$key" --body "$tmpfile" >/dev/null 2>&1; then
    say "✅ Test upload OK."; return 0
  fi

  # Some buckets require SSE by policy
  say "↻ Retrying with SSE-S3 (AES256)."
  if aws_su s3api put-object --bucket "$bucket" --key "$key" --body "$tmpfile" --server-side-encryption AES256 >/dev/null 2>&1; then
    say "✅ Test upload OK with SSE-S3."; return 0
  fi

  say "❌ Upload failed. AWS said:"
  aws_su s3api put-object --bucket "$bucket" --key "$key" --body "$tmpfile" 2>&1 | sed 's/^/   /'
  return 1
}

attempt=1; max_attempts=3
until test_upload; do
  say "Configuration test failed ($attempt/$max_attempts)."
  (( attempt >= max_attempts )) && { echo "❌ Giving up after $max_attempts attempts."; exit 2; }
  confirm "Open 'aws configure' for '$SERVICE_USER' now?" && { sudo -u "$SERVICE_USER" aws configure || true; }
  attempt=$((attempt+1))
done

# Timer override
SERVICE="v5-log-processor.service"
TIMER="v5-log-processor.timer"
DROP_DIR="/etc/systemd/system/${TIMER}.d"
OVERRIDE="${DROP_DIR}/override.conf"
sudo mkdir -p "$DROP_DIR"
{
  echo "[Timer]"
  echo "OnCalendar="
  echo "OnUnitActiveSec="
  case "$SCHEDULE_TYPE" in
    hourly)  echo "OnCalendar=hourly"  ;;
    daily)   echo "OnCalendar=daily"   ;;
    weekly)  echo "OnCalendar=weekly"  ;;
    monthly) echo "OnCalendar=monthly" ;;
    yearly)  echo "OnCalendar=yearly"  ;;
    custom)  echo "OnUnitActiveSec=${RUN_INTERVAL}" ;;
  esac
  echo "Persistent=true"
} | sudo tee "$OVERRIDE" >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable "$TIMER" >/dev/null
sudo systemctl restart "$TIMER"
say "⏱  Timer updated and started: $TIMER"
say "✅ Configuration complete."
