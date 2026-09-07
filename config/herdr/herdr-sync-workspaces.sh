# shellcheck shell=bash

set -euo pipefail

usage() {
  echo "usage: herdr-sync-workspaces REPO_CONTAINER" >&2
  exit 64
}

die() {
  echo "herdr-sync-workspaces: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
[[ -n ${HOME:-} ]] || die "HOME is not set"

work_root=$(realpath -e -- "$HOME/work") || die "managed work root does not exist: $HOME/work"
repo_container=$(realpath -e -- "$1") || die "repository container does not exist: $1"
[[ -d $repo_container ]] || die "repository container is not a directory: $repo_container"

repo=$(basename -- "$repo_container")
owner_container=$(dirname -- "$repo_container")
owner=$(basename -- "$owner_container")
[[ $(dirname -- "$owner_container") == "$work_root" ]] ||
  die "expected repository container at $work_root/<owner>/<repo>: $repo_container"

# Herdr has no atomic create-if-absent operation. Serialize the complete sync
# so concurrent helpers cannot both plan and create the same canonical Space.
lock_root=${XDG_RUNTIME_DIR:-$HOME/.cache}
mkdir -p -- "$lock_root"
lock_file="$lock_root/herdr-sync-workspaces.lock"
exec 9>"$lock_file"
flock -n 9 || die "another herdr-sync-workspaces process is running"

# Locate the primary checkout using Git's own git-dir/common-dir relationship.
# This avoids assuming that the default branch or checkout is named main/master.
primary=
primary_count=0
shopt -s nullglob dotglob
for checkout in "$repo_container"/*; do
  [[ -d $checkout ]] || continue
  if git_dirs=$(git -C "$checkout" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null); then
    git_dir=$(printf '%s\n' "$git_dirs" | head -n 1)
    common_dir=$(printf '%s\n' "$git_dirs" | tail -n 1)
    if [[ $git_dir == "$common_dir" ]]; then
      primary=$(realpath -e -- "$checkout")
      ((primary_count += 1))
    fi
  fi
done
((primary_count == 1)) ||
  die "expected exactly one primary Git checkout directly below $repo_container; found $primary_count"

primary_common_dir=$(git -C "$primary" rev-parse --path-format=absolute --git-common-dir) ||
  die "cannot read Git metadata from primary checkout: $primary"

inventory_file=$(mktemp)
trap 'rm -f -- "$inventory_file"' EXIT
git -C "$primary" worktree list --porcelain -z >"$inventory_file" ||
  die "cannot list Git worktrees from primary checkout: $primary"

declare -a worktrees=()
while IFS= read -r -d '' field; do
  if [[ $field == "worktree "* ]]; then
    checkout=${field#worktree }
    checkout=$(realpath -e -- "$checkout") || die "Git worktree path does not exist: $checkout"
    [[ $(dirname -- "$checkout") == "$repo_container" ]] ||
      die "Git worktree is not directly below repository container: $checkout"
    checkout_common_dir=$(git -C "$checkout" rev-parse --path-format=absolute --git-common-dir) ||
      die "cannot read Git metadata from worktree: $checkout"
    [[ $checkout_common_dir == "$primary_common_dir" ]] ||
      die "worktree belongs to a different Git repository: $checkout"
    worktrees+=("$checkout")
  fi
done <"$inventory_file"

((${#worktrees[@]} > 0)) || die "Git reported no worktrees for primary checkout: $primary"
primary_in_inventory=0
declare -a linked_worktrees=()
for checkout in "${worktrees[@]}"; do
  if [[ $checkout == "$primary" ]]; then
    ((primary_in_inventory += 1))
  else
    linked_worktrees+=("$checkout")
  fi
done
((primary_in_inventory == 1)) || die "primary checkout is not unique in Git worktree inventory"

# Both server reads and all response validation happen before the first mutation.
worktree_json=$(herdr worktree list --cwd "$primary" --json) ||
  die "cannot list Herdr worktrees; is the Herdr server reachable?"
workspace_json=$(herdr workspace list) ||
  die "cannot list Herdr workspaces; is the Herdr server reachable?"

config_root=${XDG_CONFIG_HOME:-$HOME/.config}/herdr
if [[ -n ${HERDR_SOCKET_PATH:-} ]]; then
  socket_path=$HERDR_SOCKET_PATH
elif [[ -n ${HERDR_SESSION:-} ]]; then
  socket_path="$config_root/sessions/$HERDR_SESSION/herdr.sock"
else
  socket_path="$config_root/herdr.sock"
fi
ping_request=$(jq -cn '{id: "herdr-sync-workspaces:ping", method: "ping", params: {}}')
ping_response=$(socat - "UNIX-CONNECT:$socket_path" <<<"$ping_request") ||
  die "cannot reach Herdr socket API: $socket_path"
jq -e '
  .id == "herdr-sync-workspaces:ping" and .result.type == "pong"
' >/dev/null <<<"$ping_response" || die "Herdr returned an invalid socket ping response"

jq -e '
  .result.type == "worktree_list"
  and (.result.worktrees | type == "array")
  and all(.result.worktrees[];
    (.path | type == "string")
    and (.label | type == "string")
    and (.is_linked_worktree | type == "boolean")
    and (.open_workspace_id == null or (.open_workspace_id | type == "string")))
  and (([.result.worktrees[].open_workspace_id | select(. != null)] | unique | length)
    == ([.result.worktrees[].open_workspace_id | select(. != null)] | length))
' >/dev/null <<<"$worktree_json" || die "Herdr returned an invalid worktree-list JSON response"

jq -e '
  .result.type == "workspace_list"
  and (.result.workspaces | type == "array")
  and all(.result.workspaces[];
    (.workspace_id | type == "string") and (.label | type == "string"))
  and (([.result.workspaces[].workspace_id] | unique | length) == (.result.workspaces | length))
' >/dev/null <<<"$workspace_json" || die "Herdr returned an invalid workspace-list JSON response"

declare -a action_kinds=()
declare -a action_paths=()
declare -a action_ids=()
declare -a action_labels=()

primary_matches=$(jq --arg path "$primary" '[.result.worktrees[] | select(.path == $path)] | length' <<<"$worktree_json")
[[ $primary_matches == 1 ]] || die "Herdr worktree inventory has $primary_matches entries for primary checkout: $primary"

for checkout in "${linked_worktrees[@]}"; do
  slot=$(basename -- "$checkout")
  label="$repo/$slot"
  legacy_label="$owner/$repo/$slot"
  matches=$(jq --arg path "$checkout" '[.result.worktrees[] | select(.path == $path)] | length' <<<"$worktree_json")
  [[ $matches == 1 ]] || die "Herdr worktree inventory has $matches entries for Git worktree: $checkout"
  workspace_id=$(jq -r --arg path "$checkout" '.result.worktrees[] | select(.path == $path) | .open_workspace_id // empty' <<<"$worktree_json")
  label_matches=$(jq --arg label "$label" '[.result.workspaces[] | select(.label == $label)] | length' <<<"$workspace_json")
  legacy_matches=$(jq --arg label "$legacy_label" '[.result.workspaces[] | select(.label == $label)] | length' <<<"$workspace_json")
  [[ $label_matches -le 1 ]] || die "Herdr workspace inventory has $label_matches Spaces labelled $label"
  [[ $legacy_matches -le 1 ]] || die "Herdr workspace inventory has $legacy_matches Spaces labelled $legacy_label"

  current_label=
  if [[ -n $workspace_id ]]; then
    workspace_matches=$(jq --arg id "$workspace_id" '[.result.workspaces[] | select(.workspace_id == $id)] | length' <<<"$workspace_json")
    [[ $workspace_matches == 1 ]] ||
      die "Herdr workspace inventory has $workspace_matches entries for open workspace: $workspace_id"
    current_label=$(jq -r --arg id "$workspace_id" '.result.workspaces[] | select(.workspace_id == $id) | .label' <<<"$workspace_json")
  fi

  # A canonical label is the stable identity. Herdr's checkout inference can
  # move when a shell changes directory, so it must not override that identity.
  if [[ $label_matches == 1 ]]; then
    continue
  fi

  # Migrate the unique previous owner/repository/slot identity even when its
  # shell CWD no longer lets Herdr associate it with this checkout.
  if [[ $legacy_matches == 1 ]]; then
    workspace_id=$(jq -r --arg label "$legacy_label" '.result.workspaces[] | select(.label == $label) | .workspace_id' <<<"$workspace_json")
    current_label=$legacy_label
  fi

  inferred_is_reserved=false
  if [[ $current_label != "$legacy_label" &&
    ( $current_label =~ ^[^/]+/[^/]+$ || $current_label =~ ^[^/]+/[^/]+/[^/]+$ ) ]]; then
    inferred_is_reserved=true
  fi

  if [[ -n $workspace_id && $inferred_is_reserved == false ]]; then
    action_kinds+=(rename)
    action_paths+=("$checkout")
    action_ids+=("$workspace_id")
    action_labels+=("$label")
  else
    action_kinds+=(create)
    action_paths+=("$checkout")
    action_ids+=("")
    action_labels+=("$label")
  fi
done

renamed=0
created=0
for ((index = 0; index < ${#action_kinds[@]}; index += 1)); do
  kind=${action_kinds[index]}
  checkout=${action_paths[index]}
  workspace_id=${action_ids[index]}
  label=${action_labels[index]}
  if [[ $kind == rename ]]; then
    response=$(herdr workspace rename "$workspace_id" "$label") ||
      die "failed to rename Herdr workspace $workspace_id to $label"
    jq -e --arg id "$workspace_id" --arg label "$label" '
      .result.type == "workspace_info"
      and .result.workspace.workspace_id == $id
      and .result.workspace.label == $label
    ' >/dev/null <<<"$response" || die "Herdr returned an invalid workspace-rename JSON response"
    workspace_json=$(jq --arg id "$workspace_id" --arg label "$label" '
      (.result.workspaces[] | select(.workspace_id == $id) | .label) = $label
    ' <<<"$workspace_json")
    echo "renamed $workspace_id as $label"
    ((renamed += 1))
  else
    response=$(herdr workspace create --cwd "$checkout" --label "$label" --no-focus) ||
      die "failed to create Herdr workspace for $checkout"
    jq -e --arg label "$label" '
      .result.type == "workspace_created"
      and (.result.workspace.workspace_id | type == "string")
      and .result.workspace.label == $label
    ' >/dev/null <<<"$response" || die "Herdr returned an invalid workspace-create JSON response"
    created_workspace=$(jq -c '.result.workspace' <<<"$response")
    workspace_json=$(jq --argjson workspace "$created_workspace" '
      .result.workspaces += [$workspace]
    ' <<<"$workspace_json")
    echo "created $label for $checkout"
    ((created += 1))
  fi
done

current_order=$(jq -c '[.result.workspaces[].workspace_id]' <<<"$workspace_json")
sorted_order=$(jq -c '[.result.workspaces | sort_by(.label, .workspace_id)[].workspace_id]' <<<"$workspace_json")
sorted=0
if [[ $current_order != "$sorted_order" ]]; then
  sort_request=$(jq -cn --argjson workspace_ids "$sorted_order" '
    {
      id: "herdr-sync-workspaces:sort",
      method: "workspace.move_block",
      params: {workspace_ids: $workspace_ids}
    }
  ')
  sort_response=$(socat - "UNIX-CONNECT:$socket_path" <<<"$sort_request") ||
    die "failed to sort Herdr workspaces"
  jq -e --argjson expected "$sorted_order" '
    .id == "herdr-sync-workspaces:sort"
    and .result.type == "workspace_list"
    and ([.result.workspaces[].workspace_id] == $expected)
  ' >/dev/null <<<"$sort_response" || die "Herdr returned an invalid workspace-sort JSON response"
  sorted=1
fi

echo "synced ${#linked_worktrees[@]} linked worktree(s): $created created, $renamed renamed, $sorted sorted"