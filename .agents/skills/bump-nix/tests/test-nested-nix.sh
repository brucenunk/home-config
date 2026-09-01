#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
skill_dir=$(cd "$(dirname "$0")/.." && pwd)
runner="$skill_dir/scripts/nix-with-gh-token"
summarizer="$skill_dir/scripts/summarize-nix-log"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bump-nix-test.XXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
mkdir -p "$tmp/fake" "$tmp/helper-tmp"
export TMPDIR="$tmp/helper-tmp"

cat >"$tmp/fake/gh" <<'EOF'
#!/usr/bin/env bash
case ${1:-}:${2:-} in
  auth:status) exit "${FAKE_GH_STATUS:-0}" ;;
  auth:token)
    [[ ${FAKE_GH_EMPTY:-0} != 1 ]] && printf '%s\n' test-token-must-not-leak
    exit "${FAKE_GH_TOKEN_STATUS:-0}"
    ;;
esac
exit 64
EOF
chmod 700 "$tmp/fake/gh"

cat >"$tmp/fake/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${github_token+x} ]] || exit 68
[[ ${NIX_CONFIG-} == "${EXPECTED_NIX_CONFIG-}" ]] || exit 69
expected=github.com=test-token-must-not-leak
previous=
found=0
internal=0
for argument in "$@"; do
  [[ $previous == extra-access-tokens && $argument == "$expected" ]] && found=1
  [[ $argument == internal-json ]] && internal=1
  previous=$argument
done
(( found == 1 )) || exit 65
for argument in "$@"; do
  if [[ $argument == flood ]]; then
    for _ in {1..10000}; do
      printf '%080d\n' 0 >&2
    done
    exit 0
  fi
done
if (( internal == 1 )); then
  printf '%s\n' "diagnostic option=$expected" >&2
  printf '%s\n' '@nix {"action":"start","id":1,"text":"building '\''/nix/store/example.drv'\''","type":105}' >&2
  printf '%s\n' '@nix {"action":"stop","id":1}' >&2
fi
for argument in "$@"; do
  [[ $argument != fail ]] || exit 23
done
case " $* " in
  *' activationPackage.system '*) printf '%s\n' x86_64-linux ;;
  *' config.home.username '*) printf '%s\n' james ;;
  *' config.home.homeDirectory '*) printf '%s\n' /home/james ;;
  *' config.home.stateVersion '*) printf '%s\n' 24.11 ;;
  *' build '*) printf '%s\n' /nix/store/test-activation ;;
  *) printf '%s\n' nested-ok ;;
esac
EOF
chmod 700 "$tmp/fake/nix"

printf '%s\n' 'Checking authentication prerequisites...'
status=0
FAKE_GH_STATUS=1 PATH="$tmp/fake:$PATH" "$runner" -- true \
  >/dev/null 2>"$tmp/auth-stderr" || status=$?
[[ $status == 1 ]] || fail "auth failure exited $status"
status=0
FAKE_GH_EMPTY=1 PATH="$tmp/fake:$PATH" "$runner" -- true \
  >/dev/null 2>"$tmp/empty-stderr" || status=$?
[[ $status == 1 ]] || fail "empty token exited $status"
status=0
GH_TOKEN=secret-from-environment PATH="$tmp/fake:$PATH" "$runner" -- true \
  >/dev/null 2>"$tmp/environment-stderr" || status=$?
[[ $status == 1 ]] || fail "environment token exited $status"
if rg -F secret-from-environment "$tmp/environment-stderr"; then
  fail 'environment token leaked'
fi

printf '%s\n' 'Checking additive direct and nested Nix options...'
direct=$(NIX_CONFIG='access-tokens = gitlab.example=existing' \
  nix --extra-experimental-features nix-command \
  --option extra-access-tokens github.com=added show-config --json)
jq -e '."access-tokens".value["gitlab.example"] == "existing" and ."access-tokens".value["github.com"] == "added"' \
  <<<"$direct" >/dev/null || fail 'direct additive token option replaced configuration'
cat >"$tmp/wrapper" <<'EOF'
#!/usr/bin/env bash
nix nested
nix fail
EOF
chmod 700 "$tmp/wrapper"
output=$(EXPECTED_NIX_CONFIG='builders = preserved' NIX_CONFIG='builders = preserved' \
  PATH="$tmp/fake:$PATH" "$runner" -- sh -c 'nix nested')
[[ $output == nested-ok ]] || fail 'nested Nix did not run through the shim'
cat >"$tmp/debug-bash-env" <<'EOF'
trap 'if [[ -n ${github_token:-} ]]; then printf "debug-token=%s\n" "$github_token" >&2; fi' DEBUG
EOF
output=$(BASH_ENV="$tmp/debug-bash-env" PATH="$tmp/fake:$PATH" \
  "$runner" -- sh -c 'nix nested' 2>"$tmp/debug-bash-env-stderr")
[[ $output == nested-ok ]] || fail 'BASH_ENV test did not run nested Nix'
if rg -F test-token-must-not-leak "$tmp/debug-bash-env-stderr"; then
  fail 'BASH_ENV DEBUG trap observed the GitHub token'
fi
mkdir -p "$tmp/relative-tmp"
output=$(
  cd "$tmp"
  TMPDIR=relative-tmp PATH="$tmp/fake:$PATH" "$runner" -- \
    sh -c 'cd /; nix nested'
)
[[ $output == nested-ok ]] \
  || fail 'relative TMPDIR made the Nix shim depend on wrapper cwd'

printf '%s\n' 'Checking the inspected repository verification wrapper...'
PATH="$tmp/fake:$PATH" "$runner" --log-file "$tmp/repository-check.jsonl" -- \
  "$repo_root/scripts/check-home-configuration" . 'james@wampa' \
  >"$tmp/repository-check-stdout" 2>"$tmp/repository-check-stderr"
rg -F 'configuration=james@wampa' "$tmp/repository-check-stdout" >/dev/null \
  || fail 'repository wrapper did not complete'
"$summarizer" "$tmp/repository-check.jsonl" >"$tmp/repository-check-summary"
rg -F 'Nested Nix invocation markers: 5 starts, 5 matched stops' \
  "$tmp/repository-check-summary" >/dev/null \
  || fail 'repository wrapper no longer performs five sequential visible Nix calls'

printf '%s\n' 'Checking command execution failure propagation...'
status=0
PATH="$tmp/fake:$PATH" "$runner" -- command-that-does-not-exist \
  >/dev/null 2>"$tmp/missing-stderr" || status=$?
[[ $status == 127 ]] || fail "missing command exited $status instead of 127"
printf '%s\n' '#!/bin/sh' >"$tmp/not-executable"
chmod 600 "$tmp/not-executable"
status=0
PATH="$tmp/fake:$PATH" "$runner" -- "$tmp/not-executable" \
  >/dev/null 2>"$tmp/nonexec-stderr" || status=$?
[[ $status == 126 ]] || fail "non-executable command exited $status instead of 126"
cat >"$tmp/signal-wrapper" <<EOF
#!/usr/bin/env bash
trap 'printf stopped >"$tmp/signal-received"; exit 0' TERM
printf ready >"$tmp/signal-ready"
while :; do sleep 1; done
EOF
chmod 700 "$tmp/signal-wrapper"
status=0
PATH="$tmp/fake:$PATH" "$runner" -- "$tmp/signal-wrapper" &
runner_pid=$!
for _ in {1..50}; do
  [[ -e $tmp/signal-ready ]] && break
  sleep 0.1
done
[[ -e $tmp/signal-ready ]] || fail 'signal wrapper did not become ready'
kill -TERM "$runner_pid"
wait "$runner_pid" || status=$?
[[ $status == 143 ]] || fail "terminated helper exited $status instead of 143"
[[ -e $tmp/signal-received ]] || fail 'helper did not terminate its wrapper'

printf '%s\n' 'Checking nested failure propagation, structured summary, and redaction...'
printf '%s\n' 'set -e' >"$tmp/bash-env"
status=0
BASH_ENV="$tmp/bash-env" PATH="$tmp/fake:$PATH" \
  "$runner" --log-file "$tmp/run.jsonl" -- \
  "$tmp/wrapper" >"$tmp/stdout" 2>"$tmp/stderr" || status=$?
[[ $status == 23 ]] || fail "nested failure exited $status instead of 23"
if rg -F test-token-must-not-leak "$tmp/run.jsonl" "$tmp/stderr"; then
  fail 'GitHub token leaked into structured stderr capture'
fi
rg -F '<redacted-github-token>' "$tmp/run.jsonl" >/dev/null \
  || fail 'redaction marker missing'
"$summarizer" "$tmp/run.jsonl" >"$tmp/summary"
rg -F 'Exit status: 23' "$tmp/summary" >/dev/null || fail 'summary status missing'
rg -F 'Nested Nix invocation markers: 2 starts, 2 matched stops' "$tmp/summary" >/dev/null \
  || fail 'summary invocation count missing'
rg -F 'Derivation Builds: 2 stopped, 0 still active at capture end' "$tmp/summary" >/dev/null \
  || fail 'summary build count missing'
cat >"$tmp/finalizer-failure-wrapper" <<'EOF'
#!/usr/bin/env bash
nix nested
chmod 400 "$FINALIZER_LOG"
EOF
chmod 700 "$tmp/finalizer-failure-wrapper"
status=0
FINALIZER_LOG="$tmp/finalizer-failure.jsonl" PATH="$tmp/fake:$PATH" \
  "$runner" --log-file "$tmp/finalizer-failure.jsonl" -- \
  "$tmp/finalizer-failure-wrapper" >/dev/null 2>"$tmp/finalizer-failure-stderr" \
  || status=$?
chmod 600 "$tmp/finalizer-failure.jsonl"
[[ $status != 0 ]] || fail 'structured-log finalization failure was ignored'

printf '%s\n' 'Checking early logger failure cannot block a noisy command...'
mkdir -p "$tmp/failing-python"
real_python=$(command -v python3)
cat >"$tmp/failing-python/python3" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == */timestamp-nix-log ]]; then
  (umask 077 && : >"$2")
  read -r _token
  read -r _first_command_line || true
  exit 74
fi
exec "${REAL_PYTHON:?}" "$@"
EOF
chmod 700 "$tmp/failing-python/python3"
status=0
REAL_PYTHON="$real_python" PATH="$tmp/failing-python:$tmp/fake:$PATH" \
  "$runner" --log-file "$tmp/logger-failure.jsonl" -- \
  sh -c 'nix flood' >/dev/null 2>"$tmp/logger-failure-stderr" || status=$?
[[ $status != 0 ]] || fail 'early logger failure was ignored'
"$summarizer" "$tmp/logger-failure.jsonl" >"$tmp/logger-failure-summary"
rg -F 'WARNING: the structured capture did not finish cleanly' \
  "$tmp/logger-failure-summary" >/dev/null \
  || fail 'logger failure was not recorded as an unhealthy capture'
if rg -F 'Exit status: 0' "$tmp/logger-failure-summary" >/dev/null; then
  fail 'logger failure was recorded as a successful command'
fi

printf '%s\n' 'Checking overwrite refusal and malformed-capture handling...'
printf existing >"$tmp/existing.jsonl"
status=0
PATH="$tmp/fake:$PATH" "$runner" --log-file "$tmp/existing.jsonl" -- true \
  >/dev/null 2>/dev/null || status=$?
[[ $status == 1 && $(<"$tmp/existing.jsonl") == existing ]] \
  || fail 'existing log was overwritten'
printf '%s\n' '[]' >"$tmp/malformed.jsonl"
status=0
"$summarizer" "$tmp/malformed.jsonl" >/dev/null 2>"$tmp/malformed-stderr" || status=$?
[[ $status == 1 ]] || fail 'malformed capture did not fail'
rg -F 'summarize-nix-log:' "$tmp/malformed-stderr" >/dev/null \
  || fail 'malformed capture lacked a concise diagnostic'
cat >"$tmp/unmatched.jsonl" <<'EOF'
{"record":"command","event":"start","timestamp_ns":1}
{"record":"output","timestamp_ns":2,"line":"@bump-nix {\"event\":\"invocation-start\"}"}
{"record":"output","timestamp_ns":3,"line":"@nix {\"action\":\"start\",\"id\":1,\"text\":\"building '/nix/store/unmatched.drv'\",\"type\":105}"}
{"record":"output","timestamp_ns":4,"line":"@bump-nix {\"event\":\"invocation-stop\",\"status\":0}"}
{"record":"command","event":"stop","timestamp_ns":5,"status":0,"capture_healthy":true}
EOF
"$summarizer" "$tmp/unmatched.jsonl" >"$tmp/unmatched-summary"
rg -F 'WARNING: malformed structured Nix events' "$tmp/unmatched-summary" >/dev/null \
  || fail 'unmatched activity did not invalidate structured evidence'
rg -F '1 still active at capture end' "$tmp/unmatched-summary" >/dev/null \
  || fail 'unmatched activity summary was misleading'
cat >"$tmp/incomplete.jsonl" <<'EOF'
{"record":"command","event":"start","timestamp_ns":1}
{"record":"output","timestamp_ns":2,"line":"@bump-nix {\"event\":\"invocation-start\"}"}
EOF
"$summarizer" "$tmp/incomplete.jsonl" >"$tmp/incomplete-summary"
rg -F 'Elapsed: unavailable (capture did not finish)' "$tmp/incomplete-summary" >/dev/null \
  || fail 'incomplete capture claimed elapsed timing'
rg -F 'WARNING: incomplete or malformed invocation boundaries' \
  "$tmp/incomplete-summary" >/dev/null \
  || fail 'incomplete invocation lacked a clear warning'

printf '%s\n' 'Checking temporary shim cleanup...'
if find "$TMPDIR" -maxdepth 1 -name 'bump-nix.*' -print -quit | grep -q .; then
  fail 'temporary shim directory remained after helper exit'
fi

printf '%s\n' 'Checking Ghostel prebuilt-module update safeguards...'
python3 "$skill_dir/tests/test-ghostel-update.py"
printf '%s\n' 'Checking project-local Pi skill discovery...'
"$skill_dir/tests/test-skill-discovery.sh"
printf '%s\n' 'PASS: bump-nix safeguards'
