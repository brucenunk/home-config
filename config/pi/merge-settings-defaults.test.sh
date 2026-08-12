#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: merge-settings-defaults.test.sh MERGER JQ BASH COREUTILS_BIN" >&2
  exit 64
fi

merger=$1
jq=$2
bash=$3
coreutils=$4
chmod=$coreutils/chmod
chown=$coreutils/chown
cp=$coreutils/cp
ln=$coreutils/ln
mv=$coreutils/mv
stat=$coreutils/stat
workspace=$(mktemp -d)
trap 'rm -rf -- "$workspace"' EXIT

defaults=$workspace/defaults.json
printf '{"provider":"default","nested":{"added":true,"kept":"default"}}\n' >"$defaults"

valid_settings=$workspace/valid/settings.json
mkdir -p -- "$(dirname -- "$valid_settings")"
printf '{"provider":"user","nested":{"kept":"user"}}\n' >"$valid_settings"
"$chmod" 0600 "$valid_settings"
valid_ownership=$("$stat" -c '%u:%g' "$valid_settings")
"$bash" "$merger" "$valid_settings" "$defaults" "$jq" "$cp" "$chmod" "$chown" "$stat" "$mv" "$ln"
"$jq" -e '
  . == {
    "provider": "default",
    "nested": {"kept": "default", "added": true}
  }
' "$valid_settings" >/dev/null
[[ $("$stat" -c %a "$valid_settings") == 600 ]]
[[ $("$stat" -c '%u:%g' "$valid_settings") == "$valid_ownership" ]]

ordinary_settings=$workspace/ordinary/settings.json
mkdir -p -- "$(dirname -- "$ordinary_settings")"
printf '{"provider":"user"}\n' >"$ordinary_settings"
"$chmod" 0640 "$ordinary_settings"
"$bash" "$merger" "$ordinary_settings" "$defaults" "$jq" "$cp" "$chmod" "$chown" "$stat" "$mv" "$ln"
[[ $("$stat" -c %a "$ordinary_settings") == 640 ]]

missing_settings=$workspace/missing/settings.json
"$bash" "$merger" "$missing_settings" "$defaults" "$jq" "$cp" "$chmod" "$chown" "$stat" "$mv" "$ln"
"$jq" -e '.provider == "default" and .nested.added == true' "$missing_settings" >/dev/null
[[ $("$stat" -c %a "$missing_settings") == 600 ]]

mkdir -p -- "$workspace/racing"
racing_settings=$workspace/racing/settings.json
racing_ln=$workspace/racing-ln
printf 'concurrent user bytes\n' >"$workspace/racing-expected"
printf '#!%s\n' "$bash" >"$racing_ln"
cat >>"$racing_ln" <<'EOF'
set -euo pipefail
destination=
for argument in "$@"; do
  destination=$argument
done
printf 'concurrent user bytes\n' >"$destination"
"$REAL_CHMOD" 0640 "$destination"
exit 1
EOF
"$chmod" 0700 "$racing_ln"
if REAL_CHMOD=$chmod \
  "$bash" "$merger" "$racing_settings" "$defaults" "$jq" \
  "$cp" "$chmod" "$chown" "$stat" "$mv" "$racing_ln" 2>"$workspace/racing-error"; then
  echo "concurrent missing-file creation unexpectedly succeeded" >&2
  exit 1
fi
cmp -- "$workspace/racing-expected" "$racing_settings"
[[ $("$stat" -c %a "$racing_settings") == 640 ]]
grep -F "refused to overwrite settings created during activation: $racing_settings" \
  "$workspace/racing-error" >/dev/null

invalid_settings=$workspace/invalid/settings.json
mkdir -p -- "$(dirname -- "$invalid_settings")"
printf '{invalid user bytes\n' >"$invalid_settings"
"$chmod" 0640 "$invalid_settings"
"$cp" --preserve=mode -- "$invalid_settings" "$workspace/invalid-before"
if "$bash" "$merger" "$invalid_settings" "$defaults" "$jq" "$cp" "$chmod" "$chown" "$stat" "$mv" "$ln" 2>"$workspace/invalid-error"; then
  echo "invalid existing settings unexpectedly succeeded" >&2
  exit 1
fi
cmp -- "$workspace/invalid-before" "$invalid_settings"
[[ $("$stat" -c %a "$invalid_settings") == 640 ]]
grep -F "refused to overwrite invalid JSON object: $invalid_settings" "$workspace/invalid-error" >/dev/null

multi_settings=$workspace/multi/settings.json
mkdir -p -- "$(dirname -- "$multi_settings")"
printf '{}\n{"second":"document"}\n' >"$multi_settings"
"$cp" --preserve=mode -- "$multi_settings" "$workspace/multi-before"
if "$bash" "$merger" "$multi_settings" "$defaults" "$jq" "$cp" "$chmod" "$chown" "$stat" "$mv" "$ln" 2>"$workspace/multi-error"; then
  echo "multi-document existing settings unexpectedly succeeded" >&2
  exit 1
fi
cmp -- "$workspace/multi-before" "$multi_settings"
grep -F "refused to overwrite invalid JSON object: $multi_settings" "$workspace/multi-error" >/dev/null

symlink_settings=$workspace/symlink/settings.json
mkdir -p -- "$(dirname -- "$symlink_settings")"
ln -s missing-target.json "$symlink_settings"
if "$bash" "$merger" "$symlink_settings" "$defaults" "$jq" "$cp" "$chmod" "$chown" "$stat" "$mv" "$ln" 2>"$workspace/symlink-error"; then
  echo "symlink settings unexpectedly succeeded" >&2
  exit 1
fi
[[ -L $symlink_settings ]]
[[ $(readlink "$symlink_settings") == missing-target.json ]]
grep -F "refused to replace symlink: $symlink_settings" "$workspace/symlink-error" >/dev/null
