#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "usage: merge-settings-defaults SETTINGS_PATH DEFAULTS_PATH JQ CP CHMOD CHOWN STAT MV LN" >&2
  exit 64
fi

settings_path=$1
defaults_path=$2
jq=$3
cp=$4
chmod=$5
chown=$6
stat=$7
mv=$8
ln=$9
settings_directory=$(dirname -- "$settings_path")

mkdir -p -- "$settings_directory"
temp_directory=$(mktemp -d "$settings_directory/.settings-defaults.XXXXXX")
trap 'rm -rf -- "$temp_directory"' EXIT

existing_json=$temp_directory/existing.json
merged_json=$temp_directory/settings.json
had_existing=false
original_identity=

if [[ -L $settings_path ]]; then
  echo "Pi settings activation refused to replace symlink: $settings_path" >&2
  exit 1
fi

if [[ -f $settings_path ]]; then
  had_existing=true
  original_identity=$("$stat" -c '%d:%i:%f:%u:%g:%s:%Y:%Z' "$settings_path")
  "$cp" --preserve=mode,ownership -- "$settings_path" "$existing_json"
  if ! "$jq" -e -s 'length == 1 and (.[0] | type == "object")' \
    "$existing_json" >/dev/null 2>&1; then
    echo "Pi settings activation refused to overwrite invalid JSON object: $settings_path" >&2
    exit 1
  fi
else
  printf '{}\n' >"$existing_json"
fi

if ! "$jq" -e -s 'length == 1 and (.[0] | type == "object")' \
  "$defaults_path" >/dev/null 2>&1; then
  echo "Pi settings defaults must contain exactly one JSON object: $defaults_path" >&2
  exit 1
fi

"$jq" -e -s '
  if length == 2 and all(.[]; type == "object") then
    .[0] * .[1]
  else
    error("settings merge requires exactly two JSON objects")
  end
' \
  "$existing_json" \
  "$defaults_path" >"$merged_json"
if [[ $had_existing == true ]]; then
  "$chown" --reference="$existing_json" "$merged_json"
  "$chmod" --reference="$existing_json" "$merged_json"
else
  "$chmod" 0600 "$merged_json"
fi

if [[ -L $settings_path ]]; then
  echo "Pi settings activation refused to replace symlink introduced during activation: $settings_path" >&2
  exit 1
fi

if [[ $had_existing == true ]]; then
  current_identity=$("$stat" -c '%d:%i:%f:%u:%g:%s:%Y:%Z' "$settings_path" 2>/dev/null || true)
  if [[ $current_identity != "$original_identity" ]] || \
    ! cmp -s -- "$existing_json" "$settings_path"; then
    echo "Pi settings activation refused to overwrite concurrently changed settings: $settings_path" >&2
    exit 1
  fi
elif [[ -e $settings_path || -L $settings_path ]]; then
  echo "Pi settings activation refused to overwrite settings created during activation: $settings_path" >&2
  exit 1
fi

if [[ $had_existing == true ]]; then
  "$mv" -fT -- "$merged_json" "$settings_path"
else
  if ! "$ln" -T -- "$merged_json" "$settings_path"; then
    echo "Pi settings activation refused to overwrite settings created during activation: $settings_path" >&2
    exit 1
  fi
fi
