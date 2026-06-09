#!/bin/bash
# Shared S3 bucket/prefix pickers for configure and manual upload menus.

if ! declare -f menu_select_cancelable >/dev/null 2>&1; then
  menu_select_cancelable() {
    local title="$1"; shift; shift; shift; shift
    local options=( "$@" ); local n=$(( ${#options[@]} / 2 ))
    echo "$title"
    for ((i=0;i<${#options[@]};i+=2)); do printf " %2d) %s\n" "$((i/2+1))" "${options[i+1]}"; done
    echo " x) Exit"
    local c
    while :; do
      read -rp "Choose [1-$n or x]: " c
      [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=n )) && { echo "${options[$(((c-1)*2))]}"; return 0; }
      [[ "$c" =~ ^[xX]$ ]] && { echo "__EXIT__"; return 0; }
      echo "Invalid choice."
    done
  }
fi

if ! declare -f aws_capture >/dev/null 2>&1; then
  aws_capture() { aws "$@" 2>/dev/null; }
fi

_s3_picker_list_prefixes() {
  local bucket_name="$1"
  local parent_prefix="${2:-}"
  local scan_contents="${3:-0}"

  if declare -f discover_child_prefixes >/dev/null 2>&1; then
    discover_child_prefixes "$bucket_name" "$parent_prefix" "$scan_contents"
    return 0
  fi

  aws_capture s3 ls "s3://${bucket_name}/${parent_prefix:+${parent_prefix}/}" 2>/dev/null \
    | awk '/PRE/ {gsub(/\//,"",$NF); print $NF}'
}

if ! declare -f sanitize_subfolder >/dev/null 2>&1; then
  sanitize_subfolder() {
    local sf="${1#/}"
    sf="${sf%/}"
    printf '%s' "$sf"
  }
fi

s3_picker_bucket_name() {
  local value="${1#s3://}"
  printf '%s' "${value%%/*}"
}

# pick_s3_bucket_into OUTVAR CURRENT_VALUE URI_PREFIX
# URI_PREFIX: "s3://" stores s3://bucket, "" stores bare bucket name
pick_s3_bucket_into() {
  local outvar="$1"
  local current="${2:-}"
  local uri_prefix="${3:-s3://}"
  local out rc opts=() choice b current_name

  current_name="$(s3_picker_bucket_name "$current")"
  out="$(aws_capture s3 ls 2>&1)"; rc=$?
  if (( rc != 0 )) || [[ -z "$out" ]]; then
    [[ -n "$current_name" ]] && opts+=( "$current_name" "$current_name (saved)" )
    opts+=( "oc4d-raw-reports" "oc4d-raw-reports" )
    opts+=( "rachel-upload-test" "rachel-upload-test" )
  else
    while IFS= read -r line; do
      b="$(echo "$line" | awk '{print $3}')"
      [[ -n "$b" ]] && opts+=( "$b" "$b" )
    done <<< "$out"
    [[ -n "$current_name" ]] && opts+=( "$current_name" "$current_name (saved)" )
  fi

  choice="$(menu_select_cancelable "Select S3 bucket (discovered via AWS CLI)" 20 74 12 "${opts[@]}")"
  [[ "$choice" == "__EXIT__" ]] && return 2
  choice="${choice% (saved)}"
  if [[ -n "$uri_prefix" ]]; then
    printf -v "$outvar" '%s' "${uri_prefix}${choice}"
  else
    printf -v "$outvar" '%s' "$choice"
  fi
}

# pick_s3_prefix_into OUTVAR BUCKET_URI PARENT_PREFIX ALLOW_NONE CURRENT_VALUE MENU_TITLE SCAN_CONTENTS
pick_s3_prefix_into() {
  local outvar="$1"
  local bucket_uri="$2"
  local parent_prefix="${3:-}"
  local allow_none="${4:-1}"
  local current="${5:-}"
  local title="${6:-Select S3 prefix}"
  local scan_contents="${7:-0}"
  local bucket_name opts=() prefixes=() p choice

  bucket_name="$(s3_picker_bucket_name "$bucket_uri")"
  parent_prefix="$(sanitize_subfolder "$parent_prefix")"
  while IFS= read -r p; do
    [[ -n "$p" ]] && prefixes+=( "$p" )
  done < <(_s3_picker_list_prefixes "$bucket_name" "$parent_prefix" "$scan_contents")
  current="$(sanitize_subfolder "$current")"
  [[ -n "$current" ]] && prefixes+=( "$current" )

  if (( allow_none )); then
    if [[ "$parent_prefix" == *RACHEL* ]]; then
      opts+=( "NONE" "<RACHEL root>" )
    else
      opts+=( "NONE" "<bucket root>" )
    fi
  fi
  while IFS= read -r p; do
    [[ -n "$p" ]] && opts+=( "$p" "$p" )
  done < <(printf '%s\n' "${prefixes[@]}" | sed '/^$/d' | LC_ALL=C sort -u)

  if (( ${#opts[@]} == 0 )); then
    printf -v "$outvar" '%s' ""
    return 0
  fi

  choice="$(menu_select_cancelable "$title" 22 74 14 "${opts[@]}")"
  [[ "$choice" == "__EXIT__" ]] && return 2
  case "$choice" in
    NONE) printf -v "$outvar" '%s' "" ;;
    *) printf -v "$outvar" '%s' "$(sanitize_subfolder "$choice")" ;;
  esac
}

# pick_s3_subfolder_select BUCKET_URI — bash `select` menu for manual upload scripts
pick_s3_subfolder_select() {
  local bucket_uri="$1"
  local bucket_name="${bucket_uri#s3://}"
  bucket_name="${bucket_name%%/*}"
  local prefixes=() selected

  while IFS= read -r selected; do
    [[ -n "$selected" ]] && prefixes+=( "$selected" )
  done < <(_s3_picker_list_prefixes "$bucket_name" "" 0)

  if (( ${#prefixes[@]} == 0 )); then
    echo "No S3 subfolders discovered in s3://${bucket_name}/" >&2
    return 1
  fi

  echo ""
  echo "Available S3 subfolders in s3://${bucket_name}/:"
  PS3="Please select the S3 subfolder: "
  select selected in "${prefixes[@]}"; do
    if [[ -n "$selected" ]]; then
      printf '%s' "$selected"
      return 0
    fi
    echo "Invalid selection. Try again."
  done
}
