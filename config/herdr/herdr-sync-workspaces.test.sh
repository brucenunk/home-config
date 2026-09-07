#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

if [[ $# -ne 7 ]]; then
  echo "usage: herdr-sync-workspaces.test.sh HELPER JQ BASH GIT COREUTILS_BIN FLOCK SOCAT" >&2
  exit 64
fi

helper=$1
jq=$2
bash=$3
git=$4
coreutils=$5
flock=$6
socat=$7
workspace=$(mktemp -d)
trap 'rm -rf -- "$workspace"' EXIT

export HOME="$workspace/home"
export XDG_RUNTIME_DIR="$workspace/runtime"
mkdir -p -- "$XDG_RUNTIME_DIR"
container="$HOME/work/owner space/repo space"
primary="$container/default checkout"
linked_a="$container/a"
linked_b="$container/b"
mkdir -p -- "$primary"
"$git" -C "$primary" init -q
"$git" -C "$primary" config user.email test@example.invalid
"$git" -C "$primary" config user.name Test
"$git" -C "$primary" commit --allow-empty -qm initial
"$git" -C "$primary" worktree add -q -b task-a "$linked_a"
"$git" -C "$primary" worktree add -q -b task-b "$linked_b"

mock_bin="$workspace/mock-bin"
mkdir -p -- "$mock_bin"
printf '#!%s\n' "$bash" >"$mock_bin/herdr"
cat >>"$mock_bin/herdr" <<'MOCK'
set -euo pipefail

"$MOCK_JQ" -cn --args '$ARGS.positional' -- "$@" >>"$MOCK_LOG"
command_name="${1:-} ${2:-}"
mode=$(cat "$MOCK_MODE")

case "$command_name" in
  "worktree list")
    [[ ${3:-} == --cwd && ${4:-} == "$MOCK_PRIMARY" && ${5:-} == --json && $# -eq 5 ]]
    [[ $mode != worktree-fail ]] || exit 2
    if [[ $mode == worktree-invalid ]]; then
      printf 'not json\n'
      exit 0
    fi
    a_id=$("$MOCK_JQ" -r --arg path "$MOCK_LINKED_A" '.open[$path] // ""' "$MOCK_STATE")
    b_id=$("$MOCK_JQ" -r --arg path "$MOCK_LINKED_B" '.open[$path] // ""' "$MOCK_STATE")
    "$MOCK_JQ" -n \
      --arg primary "$MOCK_PRIMARY" \
      --arg a "$MOCK_LINKED_A" \
      --arg b "$MOCK_LINKED_B" \
      --arg a_id "$a_id" \
      --arg b_id "$b_id" '
      {
        id: "cli:worktree:list",
        result: {
          type: "worktree_list",
          source: {repo_key: "test", repo_name: "repo space", repo_root: $primary, source_checkout_path: $primary},
          worktrees: [
            {path: $primary, label: "default checkout", is_linked_worktree: false, open_workspace_id: "ws-primary"},
            {path: $a, label: "a", is_linked_worktree: true, open_workspace_id: (if $a_id == "" then null else $a_id end)},
            {path: $b, label: "b", is_linked_worktree: true, open_workspace_id: (if $b_id == "" then null else $b_id end)}
          ]
        }
      }'
    ;;
  "workspace list")
    [[ $# -eq 2 ]]
    [[ $mode != workspace-fail ]] || exit 2
    "$MOCK_JQ" -n --slurpfile state "$MOCK_STATE" --slurpfile order "$MOCK_ORDER" '
      {
        id: "cli:workspace:list",
        result: {
          type: "workspace_list",
          workspaces: (
            ($order[0] + (($state[0].workspaces | keys) - $order[0]))
            | map(. as $id | {workspace_id: $id, label: $state[0].workspaces[$id]})
          )
        }
      }'
    ;;
  "workspace rename")
    [[ $mode != rename-fail ]] || exit 2
    [[ $# -eq 4 ]]
    id=$3
    label=$4
    temporary="$MOCK_STATE.tmp"
    "$MOCK_JQ" --arg id "$id" --arg label "$label" '.workspaces[$id] = $label' \
      "$MOCK_STATE" >"$temporary"
    mv -- "$temporary" "$MOCK_STATE"
    "$MOCK_JQ" -n --arg id "$id" --arg label "$label" \
      '{id: "cli:workspace:rename", result: {type: "workspace_info", workspace: {workspace_id: $id, label: $label}}}'
    ;;
  "workspace create")
    [[ $mode != create-fail ]] || exit 2
    [[ ${3:-} == --cwd && ${4:-} == "$MOCK_LINKED_B" && ${5:-} == --label && ${7:-} == --no-focus && $# -eq 7 ]]
    label=$6
    temporary="$MOCK_STATE.tmp"
    "$MOCK_JQ" --arg path "$MOCK_LINKED_B" --arg label "$label" \
      '.open[$path] = "ws-b" | .workspaces["ws-b"] = $label' "$MOCK_STATE" >"$temporary"
    mv -- "$temporary" "$MOCK_STATE"
    "$MOCK_JQ" 'if index("ws-b") then . else . + ["ws-b"] end' "$MOCK_ORDER" >"$MOCK_ORDER.tmp"
    mv -- "$MOCK_ORDER.tmp" "$MOCK_ORDER"
    "$MOCK_JQ" -n --arg label "$label" \
      '{id: "cli:workspace:create", result: {type: "workspace_created", workspace: {workspace_id: "ws-b", label: $label}}}'
    ;;
  *)
    echo "unexpected Herdr command: $*" >&2
    exit 2
    ;;
esac
MOCK
"$coreutils/chmod" 0700 "$mock_bin/herdr"

printf '#!%s\n' "$bash" >"$mock_bin/socat"
cat >>"$mock_bin/socat" <<'MOCK'
set -euo pipefail

request=$(cat)
printf '%s\n' "$request" >>"$MOCK_SOCKET_LOG"
[[ $(cat "$MOCK_MODE") != socket-fail ]] || exit 2
method=$("$MOCK_JQ" -r '.method' <<<"$request")
case "$method" in
  ping)
    "$MOCK_JQ" -n --arg id "$("$MOCK_JQ" -r '.id' <<<"$request")" \
      '{id: $id, result: {type: "pong"}}'
    ;;
  workspace.move_block)
    "$MOCK_JQ" '.params.workspace_ids' <<<"$request" >"$MOCK_ORDER.tmp"
    mv -- "$MOCK_ORDER.tmp" "$MOCK_ORDER"
    "$MOCK_JQ" -n \
      --arg id "$("$MOCK_JQ" -r '.id' <<<"$request")" \
      --slurpfile state "$MOCK_STATE" \
      --slurpfile order "$MOCK_ORDER" '
      {
        id: $id,
        result: {
          type: "workspace_list",
          workspaces: ($order[0] | map(. as $id | {workspace_id: $id, label: $state[0].workspaces[$id]}))
        }
      }'
    ;;
  *)
    echo "unexpected socket method: $method" >&2
    exit 2
    ;;
esac
MOCK
"$coreutils/chmod" 0700 "$mock_bin/socat"

state="$workspace/state.json"
log="$workspace/herdr.log"
mode="$workspace/mode"
order="$workspace/order.json"
socket_log="$workspace/socket.log"

reset_mock() {
  printf '%s\n' '{"open":{"'"$linked_a"'":"ws-a","'"$primary"'":"ws-primary"},"workspaces":{"ws-primary":"do not touch","ws-a":"custom"}}' >"$state"
  : >"$log"
  : >"$socket_log"
  printf '%s\n' '["ws-a","ws-primary"]' >"$order"
  printf 'ok\n' >"$mode"
}

run_helper() {
  PATH="$mock_bin:$coreutils:$(dirname -- "$git"):$(dirname -- "$jq"):$(dirname -- "$bash"):$(dirname -- "$flock"):$(dirname -- "$socat")" \
    MOCK_JQ="$jq" MOCK_LOG="$log" MOCK_MODE="$mode" MOCK_STATE="$state" \
    MOCK_ORDER="$order" MOCK_SOCKET_LOG="$socket_log" \
    MOCK_PRIMARY="$primary" MOCK_LINKED_A="$linked_a" MOCK_LINKED_B="$linked_b" \
    "$bash" "$helper" "$@"
}

expect_failure() {
  if "$@" >"$workspace/unexpected-output" 2>"$workspace/expected-error"; then
    echo "command unexpectedly succeeded: $*" >&2
    exit 1
  fi
}

# Argument and managed-topology validation happen without contacting Herdr.
reset_mock
expect_failure run_helper
expect_failure run_helper "$container" extra
outside="$workspace/outside"
mkdir -p -- "$outside"
expect_failure run_helper "$outside"
expect_failure run_helper "$primary"
[[ ! -s $log ]]

# A held global advisory lock rejects a concurrent sync before it contacts Herdr.
lock_file="$XDG_RUNTIME_DIR/herdr-sync-workspaces.lock"
(
  exec 8>"$lock_file"
  "$flock" 8
  touch "$workspace/lock-held"
  sleep 30
) &
lock_pid=$!
while [[ ! -e $workspace/lock-held ]]; do sleep 0.01; done
expect_failure run_helper "$container"
kill "$lock_pid"
wait "$lock_pid" 2>/dev/null || true
[[ ! -s $log ]]

# A Git worktree outside the managed repository container invalidates the full
# preflight before any Herdr state is changed.
invalid_container="$HOME/work/owner space/invalid repo"
invalid_primary="$invalid_container/default"
external_linked="$workspace/external-linked"
mkdir -p -- "$invalid_primary"
"$git" -C "$invalid_primary" init -q
"$git" -C "$invalid_primary" config user.email test@example.invalid
"$git" -C "$invalid_primary" config user.name Test
"$git" -C "$invalid_primary" commit --allow-empty -qm initial
"$git" -C "$invalid_primary" worktree add -q -b external "$external_linked"
expect_failure run_helper "$invalid_container"
[[ ! -s $log ]]

# Primary discovery also handles a direct child whose name starts with a dot.
hidden_container="$HOME/work/owner space/hidden repo"
hidden_primary="$hidden_container/.default"
mkdir -p -- "$hidden_primary"
"$git" -C "$hidden_primary" init -q
"$git" -C "$hidden_primary" config user.email test@example.invalid
"$git" -C "$hidden_primary" config user.name Test
"$git" -C "$hidden_primary" commit --allow-empty -qm initial
reset_mock
PATH="$mock_bin:$coreutils:$(dirname -- "$git"):$(dirname -- "$jq"):$(dirname -- "$bash"):$(dirname -- "$flock"):$(dirname -- "$socat")" \
  MOCK_JQ="$jq" MOCK_LOG="$log" MOCK_MODE="$mode" MOCK_STATE="$state" \
  MOCK_ORDER="$order" MOCK_SOCKET_LOG="$socket_log" \
  MOCK_PRIMARY="$hidden_primary" MOCK_LINKED_A="$linked_a" MOCK_LINKED_B="$linked_b" \
  "$bash" "$helper" "$hidden_container" >/dev/null
"$jq" -s -e --arg primary "$hidden_primary" '.[0] == ["worktree", "list", "--cwd", $primary, "--json"]' "$log" >/dev/null

# Read-only Herdr command failures and malformed JSON never reach mutations.
for failure_mode in worktree-fail worktree-invalid workspace-fail socket-fail; do
  reset_mock
  printf '%s\n' "$failure_mode" >"$mode"
  expect_failure run_helper "$container"
  "$jq" -s -e 'all(.[]; (.[0:2] == ["worktree", "list"] or .[0:2] == ["workspace", "list"]))' "$log" >/dev/null
done

# The previous owner/repository/slot label is migrated in place rather than
# treated as an unrelated canonical Space.
reset_mock
"$jq" '.open = {} | .workspaces["ws-a"] = "owner space/repo space/a"' "$state" >"$state.tmp"
mv -- "$state.tmp" "$state"
run_helper "$container" >/dev/null
"$jq" -e '.workspaces["ws-a"] == "repo space/a"' "$state" >/dev/null

# Canonical labels take precedence when Herdr infers a different checkout from
# a shell's current directory. The reserved a Space is preserved and b gets a
# distinct Space rather than stealing a's label.
reset_mock
"$jq" --arg b "$linked_b" '
  .open = {($b): "ws-a"}
  | .workspaces["ws-a"] = "repo space/a"
' "$state" >"$state.tmp"
mv -- "$state.tmp" "$state"
run_helper "$container" >/dev/null
"$jq" -e '
  .workspaces["ws-a"] == "repo space/a"
  and .workspaces["ws-b"] == "repo space/b"
' "$state" >/dev/null

# Canonical stale or cross-repository labels are also reserved, even though
# they are not targets in this repository's current Git inventory.
reset_mock
"$jq" --arg b "$linked_b" '
  .open[$b] = "ws-cross"
  | .workspaces["ws-a"] = "repo space/a"
  | .workspaces["ws-cross"] = "other/repository/stale"
' "$state" >"$state.tmp"
mv -- "$state.tmp" "$state"
run_helper "$container" >/dev/null
"$jq" -e '
  .workspaces["ws-cross"] == "other/repository/stale"
  and .workspaces["ws-b"] == "repo space/b"
' "$state" >/dev/null

# Ambiguous canonical labels fail during preflight rather than being reported
# as synchronized.
reset_mock
"$jq" '
  .workspaces["ws-a"] = "repo space/a"
  | .workspaces["ws-duplicate"] = "repo space/a"
' "$state" >"$state.tmp"
mv -- "$state.tmp" "$state"
: >"$log"
expect_failure run_helper "$container"
"$jq" -s -e 'all(.[]; (.[0:2] == ["worktree", "list"] or .[0:2] == ["workspace", "list"]))' "$log" >/dev/null

# Synchronize paths containing spaces. The primary/default checkout remains
# untouched, an existing linked Space is renamed, and a missing one is created.
reset_mock
git_before="$workspace/git-before"
git_after="$workspace/git-after"
"$git" -C "$primary" worktree list --porcelain >"$git_before"
run_helper "$container" >"$workspace/first-output"
"$git" -C "$primary" worktree list --porcelain >"$git_after"
cmp -- "$git_before" "$git_after"
"$jq" -e --arg a 'repo space/a' --arg b 'repo space/b' '
  .workspaces["ws-primary"] == "do not touch"
  and .workspaces["ws-a"] == $a
  and .workspaces["ws-b"] == $b
' "$state" >/dev/null
"$jq" -s -e --arg primary "$primary" --arg a "$linked_a" --arg b "$linked_b" '
  . == [
    ["worktree", "list", "--cwd", $primary, "--json"],
    ["workspace", "list"],
    ["workspace", "rename", "ws-a", "repo space/a"],
    ["workspace", "create", "--cwd", $b, "--label", "repo space/b", "--no-focus"]
  ]
' "$log" >/dev/null
"$jq" -e '. == ["ws-primary", "ws-a", "ws-b"]' "$order" >/dev/null
"$jq" -s -e '[.[].method] == ["ping", "workspace.move_block"]' "$socket_log" >/dev/null

# A second run performs only the two read-only preflight calls. Canonical
# labels remain stable identifiers even if Herdr no longer infers an ordinary
# Space's checkout association after its shell changes directory.
"$jq" '.open = {}' "$state" >"$state.tmp"
mv -- "$state.tmp" "$state"
: >"$log"
: >"$socket_log"
run_helper "$container" >"$workspace/second-output"
"$jq" -s -e --arg primary "$primary" '
  . == [
    ["worktree", "list", "--cwd", $primary, "--json"],
    ["workspace", "list"]
  ]
' "$log" >/dev/null
"$jq" -s -e '[.[].method] == ["ping"]' "$socket_log" >/dev/null
grep -F '0 created, 0 renamed' "$workspace/second-output" >/dev/null

# Mutation failures are surfaced and stop subsequent actions.
reset_mock
printf 'rename-fail\n' >"$mode"
expect_failure run_helper "$container"
"$jq" -e '.workspaces["ws-a"] == "custom" and (.workspaces | has("ws-b") | not)' "$state" >/dev/null

reset_mock
"$jq" '.workspaces["ws-a"] = "repo space/a"' "$state" >"$state.tmp"
mv -- "$state.tmp" "$state"
printf 'create-fail\n' >"$mode"
expect_failure run_helper "$container"
"$jq" -e '(.workspaces | has("ws-b") | not)' "$state" >/dev/null