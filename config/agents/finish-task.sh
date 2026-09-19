# shellcheck shell=bash
set -euo pipefail

quit_timeout=@quitTimeout@

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf 'usage: finish-task <agent-name>\n' >&2
  exit 2
fi
agent_name=$1

if [ "${HERDR_ENV:-}" != 1 ]; then
  printf 'finish-task must run from a separate Local Herdr shell pane (HERDR_ENV=1 is required)\n' >&2
  exit 1
fi
if [ -z "${HERDR_WORKSPACE_ID:-}" ] || [ -z "${HERDR_PANE_ID:-}" ] \
  || [ -z "${HERDR_SOCKET_PATH:-}" ] || [ ! -S "$HERDR_SOCKET_PATH" ]; then
  printf 'finish-task cannot find the Local Herdr control context for this pane\n' >&2
  exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/finish-task.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

if ! timeout 30 herdr pane current --current >"$tmp/caller.json" \
  || ! jq -e '.result.pane.pane_id | type == "string"' "$tmp/caller.json" >/dev/null \
  || ! jq -e '.result.pane.workspace_id | type == "string"' "$tmp/caller.json" >/dev/null \
  || ! jq -e '.result.pane.agent == null' "$tmp/caller.json" >/dev/null; then
  printf 'finish-task must run from a separate Local Herdr shell pane with no agent\n' >&2
  exit 1
fi
caller_pane=$(jq -r '.result.pane.pane_id' "$tmp/caller.json")
caller_workspace=$(jq -r '.result.pane.workspace_id' "$tmp/caller.json")
if ! timeout 30 herdr machine list --json >"$tmp/machines.json"; then
  printf 'finish-task cannot enumerate saved Herdr machines; no changes made\n' >&2
  exit 1
fi
if ! jq -e 'type == "array" and all(.[];
  (.id | type == "string") and (.label | type == "string") and (.enabled | type == "boolean"))' \
  "$tmp/machines.json" >/dev/null; then
  printf 'finish-task received invalid saved-machine inventory; no changes made\n' >&2
  exit 1
fi
jq -n --slurpfile machines "$tmp/machines.json" \
  '[{label:"Local", selector:null}] +
   [$machines[0][] | select(.enabled) | {label, selector:.id}]' >"$tmp/servers.json"
: >"$tmp/matches.jsonl"

call_herdr() {
  selector=$1
  shift
  if [ -n "$selector" ]; then
    timeout 30 herdr --machine "$selector" "$@"
  else
    timeout 30 herdr "$@"
  fi
}
valid_agents() {
  jq -e '(.result.agents | type == "array") and all(.result.agents[];
    (.name == null or (.name | type == "string")) and
    (.agent == null or (.agent | type == "string")) and
    (.agent_status | type == "string") and (.workspace_id | type == "string") and
    (.pane_id | type == "string"))' "$1" >/dev/null
}
valid_workspaces() {
  jq -e '(.result.workspaces | type == "array") and all(.result.workspaces[];
    (.workspace_id | type == "string") and (.label | type == "string") and
    (.worktree == null or ((.worktree | type == "object") and
      (.worktree.checkout_path | type == "string") and
      (.worktree.repo_key | type == "string") and
      (.worktree.is_linked_worktree | type == "boolean"))))' "$1" >/dev/null
}

server_count=$(jq 'length' "$tmp/servers.json")
for ((i = 0; i < server_count; i++)); do
  label=$(jq -r ".[${i}].label" "$tmp/servers.json")
  selector=$(jq -r ".[${i}].selector // empty" "$tmp/servers.json")
  if ! call_herdr "$selector" agent list >"$tmp/agents-$i.json" \
    || ! call_herdr "$selector" workspace list >"$tmp/workspaces-$i.json" \
    || ! valid_agents "$tmp/agents-$i.json" \
    || ! valid_workspaces "$tmp/workspaces-$i.json"; then
    printf 'finish-task could not inspect %s; no changes made\n' "$label" >&2
    exit 1
  fi
  jq -c --arg name "$agent_name" --arg label "$label" --arg selector "$selector" \
    --slurpfile workspaces "$tmp/workspaces-$i.json" \
    '.result.agents[] | select(.name == $name) | . as $agent
     | {machine_label:$label,
        machine_selector:($selector | if . == "" then null else . end),
        agent:$agent,
        workspace:([$workspaces[0].result.workspaces[]
          | select(.workspace_id == $agent.workspace_id)][0] // null)}' \
    "$tmp/agents-$i.json" >>"$tmp/matches.jsonl"
done
jq -s '.' "$tmp/matches.jsonl" >"$tmp/matches.json"

count=$(jq 'length' "$tmp/matches.json")
if [ "$count" -eq 0 ]; then
  printf 'finish-task found no exact live agent named %s across %s\n' "$agent_name" \
    "$(jq -r 'map(.label) | join(", ")' "$tmp/servers.json")" >&2
  exit 1
fi
if [ "$count" -ne 1 ]; then
  printf 'finish-task found multiple exact live agents named %s; no changes made:\n' "$agent_name" >&2
  jq -r '.[] | "  \(.machine_label): \(.workspace.label // .agent.workspace_id)"' \
    "$tmp/matches.json" >&2
  exit 1
fi

jq '.[0]' "$tmp/matches.json" >"$tmp/target.json"
label=$(jq -r '.machine_label' "$tmp/target.json")
selector=$(jq -r '.machine_selector // empty' "$tmp/target.json")
workspace_id=$(jq -r '.agent.workspace_id // empty' "$tmp/target.json")
pane_id=$(jq -r '.agent.pane_id // empty' "$tmp/target.json")
status=$(jq -r '.agent.agent_status // "unknown"' "$tmp/target.json")
kind=$(jq -r '.agent.agent // "unknown"' "$tmp/target.json")

if [ -z "$selector" ] && { [ "$pane_id" = "$caller_pane" ] \
  || [ "$workspace_id" = "$caller_workspace" ]; }; then
  printf 'finish-task refuses to remove the calling Local pane or workspace\n' >&2
  exit 1
fi
if ! jq -e '.agent.agent == "pi"
  and (.agent.agent_status == "idle" or .agent.agent_status == "done")
  and .workspace.workspace_id == .agent.workspace_id
  and .workspace.worktree.is_linked_worktree == true' "$tmp/target.json" >/dev/null; then
  printf 'finish-task refuses %s on %s: requires idle/done Pi in a linked-worktree workspace (kind=%s, status=%s)\n' \
    "$agent_name" "$label" "$kind" "$status" >&2
  exit 1
fi

if ! call_herdr "$selector" worktree list --workspace "$workspace_id" >"$tmp/worktrees.json"; then
  printf 'finish-task cannot inspect the target worktree on %s; no changes made\n' "$label" >&2
  exit 1
fi
parent_id=$(jq -r '.result.source.source_workspace_id // empty' "$tmp/worktrees.json")
path=$(jq -r --arg workspace "$workspace_id" \
  '[.result.worktrees[] | select(.open_workspace_id == $workspace and .is_linked_worktree)][0].path // empty' \
  "$tmp/worktrees.json")
if [ -z "$parent_id" ] || [ "$parent_id" = "$workspace_id" ] || [ -z "$path" ] \
  || ! call_herdr "$selector" workspace get "$parent_id" >"$tmp/parent.json" \
  || ! jq -e '.result.workspace.workspace_id | type == "string"' "$tmp/parent.json" >/dev/null \
  || ! jq -e '.result.workspace.label | type == "string"' "$tmp/parent.json" >/dev/null \
  || ! jq -e '.result.workspace.worktree.is_linked_worktree == false' "$tmp/parent.json" >/dev/null; then
  printf 'finish-task refuses %s: linked checkout parent is missing or invalid\n' "$agent_name" >&2
  exit 1
fi

if ! call_herdr "$selector" agent prompt "$agent_name" "/quit" \
  >"$tmp/prompt.json" 2>"$tmp/prompt.err"; then
  cat "$tmp/prompt.err" >&2
  printf 'finish-task could not confirm /quit; state is uncertain and no removal was attempted\n' >&2
  exit 1
fi

deadline=$((SECONDS + quit_timeout))
while :; do
  if ! call_herdr "$selector" agent list >"$tmp/after.json"; then
    printf 'finish-task lost contact after /quit; state is uncertain and no removal was attempted\n' >&2
    exit 1
  fi
  if ! valid_agents "$tmp/after.json"; then
    printf 'finish-task received invalid state after /quit; state is uncertain and no removal was attempted\n' >&2
    exit 1
  fi
  if ! jq -e --arg name "$agent_name" '.result.agents[] | select(.name == $name)' "$tmp/after.json" >/dev/null; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    printf 'finish-task timed out after /quit; state is uncertain and no removal was attempted\n' >&2
    exit 1
  fi
  sleep 1
done

if ! call_herdr "$selector" worktree remove --workspace "$workspace_id" \
  >"$tmp/remove.json" 2>"$tmp/remove.err"; then
  cat "$tmp/remove.err" >&2
  printf 'finish-task could not confirm removal; state is uncertain and removal was not retried\n' >&2
  exit 1
fi
if ! jq -e --arg workspace "$workspace_id" --arg path "$path" \
  '.result.type == "worktree_removed" and .result.workspace_id == $workspace
   and .result.path == $path and .result.forced == false' "$tmp/remove.json" >/dev/null; then
  printf 'finish-task received an unexpected removal result; state is uncertain and removal was not retried\n' >&2
  exit 1
fi

parent_label=$(jq -r '.result.workspace.label' "$tmp/parent.json")
task_label=$(jq -r '.workspace.label' "$tmp/target.json")
printf 'Finished %s on %s: parent %s; removed task workspace %s at %s\n' \
  "$agent_name" "$label" "$parent_label" "$task_label" "$path"
