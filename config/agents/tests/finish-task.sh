# shellcheck shell=bash
set -euo pipefail

root=$(mktemp -d "${TMPDIR:-/tmp}/finish-task-test.XXXXXXXX")
socket_pid=
cleanup() {
  [ -z "$socket_pid" ] || kill "$socket_pid" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT
mkdir "$root/bin"

cat >"$root/bin/herdr" <<'PY'
#!@python@
import json, os, sys
args = sys.argv[1:]
scenario = os.environ.get("SCENARIO", "success")
state_file, log_file = os.environ["MOCK_STATE"], os.environ["MOCK_LOG"]
state = open(state_file).read().strip() or "initial"
machine = "Local"
if args[:1] == ["--machine"]:
    machine, args = "devbox", args[2:]

def emit(value): print(json.dumps({"id":"mock", "result":value}))
def agent():
    status = scenario if scenario in ("working", "blocked", "unknown") else "idle"
    return {"name":"possum", "agent":"claude" if scenario == "non-pi" else "pi",
            "agent_status":status, "workspace_id":"wtask",
            "pane_id":"pcaller" if scenario == "caller" else "ptask"}
def workspace():
    return {"workspace_id":"wtask", "label":"Task", "pane_count":1,
            "worktree":{"checkout_path":"/repo/task", "repo_key":"/repo/.git",
                        "is_linked_worktree":scenario != "non-worktree"}}
def parent():
    return {"workspace_id":"wparent", "label":"owner/repo", "pane_count":1,
            "worktree":{"checkout_path":"/repo/main", "repo_key":"/repo/.git",
                        "is_linked_worktree":False}}
def agents():
    if scenario == "zero":
        value = agent(); value["name"] = "quokka"; return [value]
    if machine == "devbox" and scenario != "duplicate": return []
    if state != "initial" and scenario != "timeout": return []
    return [agent()]
def worktrees():
    return {"source":{"source_workspace_id":None if scenario == "bad-parent" else "wparent"},
            "worktrees":[{"path":"/repo/task", "open_workspace_id":"wtask",
                          "is_linked_worktree":True}]}

if args == ["pane", "current", "--current"]:
    moved = scenario == "moved-caller"
    emit({"pane":{"pane_id":"pcaller-live" if moved else "pcaller",
                  "workspace_id":"wcaller-live" if moved else "wcaller"}})
elif args == ["machine", "list", "--json"]:
    if scenario == "malformed-machine": print("null"); sys.exit(0)
    enabled = scenario in ("duplicate", "machine-fail")
    print(json.dumps([{"id":"machine-id", "label":"devbox", "enabled":enabled}]))
elif scenario == "machine-fail" and machine == "devbox":
    print("connection failed", file=sys.stderr); sys.exit(1)
elif args == ["agent", "list"]:
    values = agents()
    if scenario == "malformed-agent": values[0]["workspace_id"] = None
    if scenario == "malformed-after" and state != "initial": values = None
    emit({"agents":values})
elif args == ["workspace", "list"]:
    emit({"workspaces":None if scenario == "malformed-workspace" else [workspace()]})
elif args[:2] == ["worktree", "list"]:
    emit(worktrees())
elif args == ["workspace", "get", "wparent"]:
    emit({"workspace":parent()})
elif args[:2] == ["agent", "prompt"]:
    with open(log_file, "a") as log: log.write("prompt " + " ".join(args[2:]) + "\n")
    open(state_file, "w").write("quit")
    if scenario == "prompt-fail":
        print("prompt timeout", file=sys.stderr); sys.exit(1)
    emit({})
elif args[:2] == ["worktree", "remove"]:
    with open(log_file, "a") as log: log.write("remove " + " ".join(args[2:]) + "\n")
    if scenario == "dirty":
        print("worktree contains modified or untracked files", file=sys.stderr); sys.exit(1)
    if scenario == "remove-fail":
        print("connection lost", file=sys.stderr); sys.exit(1)
    if scenario == "malformed-success": emit({})
    else: emit({"type":"worktree_removed", "workspace_id":"wtask", "path":"/repo/task", "forced":False})
else:
    print("unexpected: " + " ".join(args), file=sys.stderr); sys.exit(2)
PY
python=$(command -v python3)
sed "1s|@python@|$python|" "$root/bin/herdr" >"$root/bin/herdr.tmp"
mv "$root/bin/herdr.tmp" "$root/bin/herdr"
chmod +x "$root/bin/herdr"

socket="$root/herdr.sock"
python3 - "$socket" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(300)
PY
socket_pid=$!
for _ in 1 2 3 4 5; do [ -S "$socket" ] && break; sleep 0.1; done

export PATH="$root/bin:$PATH"
export HERDR_ENV=1 HERDR_WORKSPACE_ID=wcaller HERDR_PANE_ID=pcaller HERDR_SOCKET_PATH="$socket"
export MOCK_STATE="$root/state" MOCK_LOG="$root/log"

run_case() {
  export SCENARIO=$1
  : >"$MOCK_STATE"; : >"$MOCK_LOG"
  if "$FINISH_TASK" possum >"$root/$1.out" 2>&1; then result=success; else result=failure; fi
  [ "$result" = "$2" ] || { cat "$root/$1.out" >&2; exit 1; }
}

if "$FINISH_TASK" >"$root/usage.out" 2>&1; then exit 1; fi
grep -F 'usage: finish-task <agent-name>' "$root/usage.out"
if env -u HERDR_ENV "$FINISH_TASK" possum >"$root/context.out" 2>&1; then exit 1; fi
grep -F 'separate Local Herdr shell pane' "$root/context.out"

run_case success success
grep -Fx 'prompt possum /quit' "$MOCK_LOG"
grep -Fx 'remove --workspace wtask' "$MOCK_LOG"
grep -F 'Finished possum on Local: parent owner/repo; removed task workspace Task at /repo/task' "$root/success.out"
run_case moved-caller success
grep -F 'Finished possum on Local' "$root/moved-caller.out"

for scenario in zero duplicate machine-fail malformed-machine malformed-agent malformed-workspace working blocked unknown non-pi caller non-worktree bad-parent; do
  run_case "$scenario" failure
  [ ! -s "$MOCK_LOG" ] || { echo "$scenario mutated state" >&2; exit 1; }
done
grep -F 'no exact live agent' "$root/zero.out"
grep -F 'multiple exact live agents' "$root/duplicate.out"
grep -F 'could not inspect devbox' "$root/machine-fail.out"
grep -F 'calling Local pane or workspace' "$root/caller.out"

for scenario in prompt-fail timeout malformed-after; do
  run_case "$scenario" failure
  grep -Fx 'prompt possum /quit' "$MOCK_LOG"
  if grep -q '^remove ' "$MOCK_LOG"; then exit 1; fi
done
grep -F 'state is uncertain' "$root/prompt-fail.out"
grep -F 'timed out after /quit' "$root/timeout.out"
grep -F 'invalid state after /quit' "$root/malformed-after.out"

for scenario in dirty remove-fail malformed-success; do
  run_case "$scenario" failure
  [ "$(grep -c '^remove ' "$MOCK_LOG")" = 1 ]
done
grep -F 'modified or untracked files' "$root/dirty.out"
if grep -F -- '--force' "$MOCK_LOG"; then exit 1; fi
grep -F 'removal was not retried' "$root/remove-fail.out"
grep -F 'unexpected removal result' "$root/malformed-success.out"
