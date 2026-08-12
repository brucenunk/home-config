#!/usr/bin/env bash
set -euo pipefail

skill_dir=$(cd "$(dirname "$0")/.." && pwd)
runner="$skill_dir/scripts/nix-with-gh-token"
summarizer="$skill_dir/scripts/summarize-nix-log"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bump-nix-test.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/fake-gh"
cat >"$tmp/fake-gh/gh" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
  auth)
    case ${2:-} in
      status) exit 0 ;;
      token) printf '%s\n' 'test-token-must-not-leak'; exit 0 ;;
    esac
    ;;
esac
exit 64
EOF
chmod 700 "$tmp/fake-gh/gh"
cat >"$tmp/show-safe-config" <<'EOF'
#!/usr/bin/env sh
nix --extra-experimental-features nix-command show-config --json | jq -c '{
  "experimental-features": .["experimental-features"].value,
  "substituters": .substituters.value,
  "trusted-public-keys": .["trusted-public-keys"].value,
  "builders": .builders.value
}'
EOF
chmod 700 "$tmp/show-safe-config"

printf '%s\n' 'Checking that partial NIX_CONFIG can suppress managed settings...'
baseline_config=$("$tmp/show-safe-config")
partial_config=$(NIX_CONFIG='access-tokens = github.com=dummy-test-value' \
  "$tmp/show-safe-config")
if jq -e --argjson partial "$partial_config" '
  . as $baseline
  | ["experimental-features", "substituters", "trusted-public-keys", "builders"]
  | any(. as $key | $baseline[$key] != $partial[$key])
' <<<"$baseline_config" >/dev/null; then
  printf '%s\n' '  reproduced: partial NIX_CONFIG changed effective managed settings'
else
  printf '%s\n' '  SKIP: this host has no differing managed values to suppress'
fi
NIX_CONFIG='access-tokens = gitlab.example=existing-test-token' \
  nix --extra-experimental-features nix-command \
  --option extra-access-tokens github.com=additive-test-token show-config --json \
  | jq -e '
  .["access-tokens"].value
  | .["gitlab.example"] == "existing-test-token"
    and .["github.com"] == "additive-test-token"
' >/dev/null \
  || fail 'extra-access-tokens did not preserve the existing token map'

printf '%s\n' 'Checking that the nested-invocation shim preserves effective settings...'
wrapped_config=$(PATH="$tmp/fake-gh:$PATH" "$runner" -- "$tmp/show-safe-config")
jq -e --argjson wrapped "$wrapped_config" '
  . as $baseline
  | ["experimental-features", "substituters", "trusted-public-keys", "builders"]
  | all(. as $key | $baseline[$key] == $wrapped[$key])
' <<<"$baseline_config" >/dev/null || fail 'wrapped Nix configuration differs from baseline'
baseline_umask=$(umask)
wrapped_umask=$(PATH="$tmp/fake-gh:$PATH" "$runner" -- sh -c umask)
[[ $wrapped_umask == "$baseline_umask" ]] || fail 'wrapper inherited a changed umask'
stdin_result=$(printf expected-input | PATH="$tmp/fake-gh:$PATH" "$runner" -- \
  sh -c 'read -r value; printf "%s" "$value"')
[[ $stdin_result == expected-input ]] || fail 'wrapper could not read foreground stdin'
python3 "$skill_dir/tests/test-foreground-pty.py" "$runner" "$tmp/fake-gh"
(
  nix() { printf '%s\n' 'exported function incorrectly used' >&2; return 99; }
  export -f nix
  PATH="$tmp/fake-gh:$PATH" "$runner" -- \
    bash -c 'nix --extra-experimental-features nix-command eval --expr 1' \
    >"$tmp/function-shadow-result"
)
[[ $(<"$tmp/function-shadow-result") == 1 ]] \
  || fail 'exported shell function shadowed the PATH shim'
missing_status=0
PATH="$tmp/fake-gh:$PATH" "$runner" -- command-that-does-not-exist \
  >/dev/null 2>"$tmp/missing-stderr" || missing_status=$?
[[ $missing_status == 127 ]] || fail "missing command exited $missing_status instead of 127"
printf '%s\n' '#!/bin/sh' >"$tmp/not-executable"
chmod 600 "$tmp/not-executable"
nonexec_status=0
PATH="$tmp/fake-gh:$PATH" "$runner" -- "$tmp/not-executable" \
  >/dev/null 2>"$tmp/nonexec-stderr" || nonexec_status=$?
[[ $nonexec_status == 126 ]] \
  || fail "non-executable command exited $nonexec_status instead of 126"

printf '%s\n' 'Checking nested calls, failure propagation, logging, and redaction...'
mkdir -p "$tmp/fake-all"
cp "$tmp/fake-gh/gh" "$tmp/fake-all/gh"
cat >"$tmp/fake-all/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ -z ${BUMP_NIX_GITHUB_TOKEN+x} ]] || {
  printf '%s\n' 'wrapper inherited the GitHub token environment variable' >&2
  exit 66
}
expected='github.com=test-token-must-not-leak'
previous=
found=0
for argument in "$@"; do
  if [[ $previous == extra-access-tokens && $argument == "$expected" ]]; then
    found=1
  fi
  previous=$argument
done
(( found == 1 )) || { printf '%s\n' 'missing additive authenticated access option' >&2; exit 65; }

if [[ ${EXPECT_NO_INTERNAL_JSON:-0} == 1 ]]; then
  for argument in "$@"; do
    [[ $argument != internal-json ]] \
      || { printf '%s\n' 'inherited internal-json state reached nested Nix' >&2; exit 67; }
  done
  exit 0
fi

for argument in "$@"; do
  if [[ $argument == prompt ]]; then
    printf 'prompt> ' >&2
    read -r answer
    printf 'received:%s\n' "$answer" >&2
    printf '\377\n' >&2
    exit 0
  fi
  if [[ $argument == split-token ]]; then
    printf 'github.com=test-token-' >&2
    sleep 0.01
    printf 'must-not-leak\n' >&2
    printf 'test-token-' >&2
    sleep 0.01
    printf 'must-not-leak\n' >&2
    exit 0
  fi
  if [[ $argument == nested-signal ]]; then
    : >"${NESTED_SIGNAL_READY:?}"
    exec sleep 30
  fi
  if [[ $argument == nested-interrupt ]]; then
    printf '%s\n' 'nested-interrupt-ready' >&2
    exec sleep 30
  fi
  if [[ $argument == concurrency-hold ]]; then
    : >"${CONCURRENCY_READY:?}"
    while [[ ! -e ${CONCURRENCY_RELEASE:?} ]]; do sleep 0.01; done
    exit 0
  fi
done

printf 'diagnostic option=%s\n' "$expected" >&2
printf '%s\n' 'rotated option=github.com=another-token-must-not-leak' >&2
printf '%s\n' '@nix {"action":"start","id":101,"level":3,"parent":0,"text":"copying path '\''/nix/store/downloaded-path'\'' from '\''https://cache.example'\''","type":100}' >&2
sleep 0.01
printf '%s\n' '@nix {"action":"stop","id":101}' >&2
printf '%s\n' '@nix {"action":"start","id":102,"level":3,"parent":0,"text":"substituting '\''/nix/store/substituted-path'\''","type":108}' >&2
sleep 0.01
printf '%s\n' '@nix {"action":"stop","id":102}' >&2
derivation=/nix/store/example-package.drv
for argument in "$@"; do
  if [[ $argument == fail ]]; then
    derivation=/nix/store/failed-package.drv
  fi
done
printf '@nix {"action":"start","id":202,"level":3,"parent":0,"text":"building '\''%s'\''","type":105}\n' "$derivation" >&2
printf '%s\n' '@nix {"action":"result","fields":["representative build diagnostic"],"id":202,"type":101}' >&2
sleep 0.01
printf '%s\n' '@nix {"action":"stop","id":202}' >&2

for argument in "$@"; do
  if [[ $argument == fail ]]; then
    exit 23
  fi
done
EOF
chmod 700 "$tmp/fake-all/nix"
python3 "$skill_dir/tests/test-foreground-pty.py" \
  "$runner" "$tmp/fake-all" --nested-only

cat >"$tmp/repository-wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
nix first
nix fail
EOF
chmod 700 "$tmp/repository-wrapper"

preset_status=0
BUMP_NIX_INTERNAL_JSON_LOGS=1 EXPECT_NO_INTERNAL_JSON=1 \
  PATH="$tmp/fake-all:$PATH" "$runner" -- sh -c 'nix first' \
  >"$tmp/preset-stdout" 2>"$tmp/preset-stderr" || preset_status=$?
[[ $preset_status == 0 ]] || fail "preset private state changed no-log mode: $preset_status"
if rg -F '@bump-nix' "$tmp/preset-stdout" "$tmp/preset-stderr"; then
  fail 'inherited private state unexpectedly enabled logging mode'
fi
conflict_status=0
PATH="$tmp/fake-all:$PATH" "$runner" -- \
  sh -c 'nix --option access-tokens github.com=wrong show-config' \
  >"$tmp/conflict-stdout" 2>"$tmp/conflict-stderr" || conflict_status=$?
[[ $conflict_status == 64 ]] \
  || fail "expected conflicting-token status 64, got $conflict_status"
rg -F 'nested access-token options are unsupported' "$tmp/conflict-stderr" >/dev/null \
  || fail 'conflicting-token diagnostic missing'
application_option_status=0
PATH="$tmp/fake-all:$PATH" "$runner" -- \
  sh -c 'nix run example -- --access-tokens application-argument' \
  >"$tmp/application-option-stdout" 2>"$tmp/application-option-stderr" \
  || application_option_status=$?
[[ $application_option_status == 0 ]] \
  || fail "application argument after -- was incorrectly rejected: $application_option_status"

status=0
PATH="$tmp/fake-all:$PATH" "$runner" --log-file "$tmp/run.jsonl" -- \
  "$tmp/repository-wrapper" >"$tmp/stdout" 2>"$tmp/stderr" || status=$?
if [[ $status != 23 ]]; then
  printf '%s\n' '--- wrapper stderr ---' >&2
  <"$tmp/stderr" tail -50 >&2
  fail "expected wrapper status 23, got $status"
fi
if rg -F 'test-token-must-not-leak' "$tmp/run.jsonl" "$tmp/stdout" "$tmp/stderr"; then
  fail 'GitHub token leaked into normal output or the structured capture'
fi
if rg -F 'another-token-must-not-leak' "$tmp/run.jsonl" "$tmp/stdout" "$tmp/stderr"; then
  fail 'rotated GitHub token pattern leaked into output or the structured capture'
fi
rg -F '<redacted-github-token>' "$tmp/run.jsonl" >/dev/null \
  || fail 'redaction marker missing from capture'
rg -F 'representative build diagnostic' "$tmp/stderr" >/dev/null \
  || fail 'build-log result missing from foreground output'

"$summarizer" "$tmp/run.jsonl" --previous "$tmp/run.jsonl" >"$tmp/summary"
rg -F 'Exit status: 23' "$tmp/summary" >/dev/null || fail 'exit status missing from summary'
rg -F 'Nested Nix invocation markers: 2 starts, 2 matched stops' \
  "$tmp/summary" >/dev/null \
  || fail 'nested invocation boundary count missing from summary'
rg -F 'Substitution/Downloads: 4 stopped, 0 still active at capture end' "$tmp/summary" >/dev/null \
  || fail 'substitution count missing from summary'
rg -F 'Derivation Builds: 2 stopped, 0 still active at capture end' "$tmp/summary" >/dev/null \
  || fail 'derivation-build count missing from summary'
rg -F 'genuinely repeated after a successful prior nested invocation: 1' \
  "$tmp/summary" >/dev/null \
  || fail 'retry success boundary missing from summary'
rg -F 'reattempted after a prior stop with unknown outcome: 1' "$tmp/summary" >/dev/null \
  || fail 'retry unknown-outcome count missing from summary'
rg -F '/nix/store/example-package.drv' "$tmp/summary" >/dev/null \
  || fail 'slowest derivation missing from summary'

printf '%s\n' 'Checking partial prompts and invalid stderr bytes...'
prompt_status=0
printf 'prompt-answer\n' | PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/prompt.jsonl" -- sh -c 'nix prompt' \
  >"$tmp/prompt-stdout" 2>"$tmp/prompt-stderr" || prompt_status=$?
[[ $prompt_status == 0 ]] || fail "prompt wrapper exited $prompt_status"
python3 - "$tmp/prompt-stderr" "$tmp/prompt.jsonl" <<'PY'
import pathlib
import sys

stderr = pathlib.Path(sys.argv[1]).read_bytes()
capture = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert b"prompt> " in stderr
assert b"received:prompt-answer" in stderr
assert "�".encode() in stderr
assert "\\ufffd" in capture
PY
split_status=0
PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/split-token.jsonl" -- sh -c 'nix split-token' \
  >"$tmp/split-stdout" 2>"$tmp/split-stderr" || split_status=$?
[[ $split_status == 0 ]] || fail "split-token wrapper exited $split_status"
if rg -F 'test-token-must-not-leak' \
  "$tmp/split-token.jsonl" "$tmp/split-stdout" "$tmp/split-stderr"; then
  fail 'GitHub token split across writes was not redacted'
fi
sed 's/"status":23/"status":0/' "$tmp/run.jsonl" >"$tmp/success.jsonl"
"$summarizer" "$tmp/success.jsonl" --previous "$tmp/success.jsonl" \
  >"$tmp/success-summary"
rg -F 'genuinely repeated after a successful prior nested invocation: 1' \
  "$tmp/success-summary" >/dev/null \
  || fail 'proven repeated-work count missing from successful retry summary'
python3 - \
  "$tmp/unfinished.jsonl" "$tmp/empty-success.jsonl" "$tmp/boundary.jsonl" \
  "$tmp/missing-boundary.jsonl" "$tmp/malformed-event.jsonl" <<'PY'
import json
import sys


def write(path, status, events):
    records = [{"record": "command", "event": "start", "timestamp_ns": 1}]
    for timestamp, event in enumerate(events, 2):
        records.append(
            {
                "record": "output",
                "timestamp_ns": timestamp,
                "line": event
                if isinstance(event, str)
                else "@nix " + json.dumps(event, separators=(",", ":")),
            }
        )
    records.append(
        {
            "record": "command",
            "event": "stop",
            "timestamp_ns": 10,
            "status": status,
            "command_status": status,
            "logger_status": 0,
            "capture_healthy": True,
        }
    )
    with open(path, "w", encoding="utf-8") as target:
        for record in records:
            target.write(json.dumps(record, separators=(",", ":")) + "\n")


write(
    sys.argv[1],
    23,
    [
        '@bump-nix {"event":"invocation-start"}',
        {
            "action": "start",
            "id": 303,
            "text": "building '/nix/store/interrupted.drv'",
            "type": 105,
        },
        '@bump-nix {"event":"invocation-stop","status":23}',
    ],
)
write(
    sys.argv[2],
    0,
    [
        '@bump-nix {"event":"invocation-start"}',
        {
            "action": "start",
            "id": 304,
            "text": "building '/nix/store/current-work.drv'",
            "type": 105,
        },
        {"action": "stop", "id": 304},
        '@bump-nix {"event":"invocation-stop","status":0}',
    ],
)
write(
    sys.argv[3],
    0,
    [
        '@bump-nix {"event":"invocation-start"}',
        {
            "action": "start",
            "id": 404,
            "text": "building '/nix/store/boundary.drv'",
            "type": 105,
        },
        '@bump-nix {"event":"invocation-stop","status":23}',
        '@bump-nix {"event":"invocation-start"}',
        {"action": "stop", "id": 404},
        '@bump-nix {"event":"invocation-stop","status":0}',
    ],
)
write(
    sys.argv[4],
    23,
    [
        '@bump-nix {"event":"invocation-start"}',
        {
            "action": "start",
            "id": 505,
            "text": "building '/nix/store/missing-boundary.drv'",
            "type": 105,
        },
    ],
)
write(
    sys.argv[5],
    0,
    [
        '@bump-nix {"event":"invocation-start"}',
        "@nix []",
        '@bump-nix {"event":"invocation-stop","status":0}',
    ],
)
PY
"$summarizer" "$tmp/empty-success.jsonl" --previous "$tmp/unfinished.jsonl" \
  >"$tmp/unfinished-summary"
rg -F 'prior unfinished work not observed in retry: 1' \
  "$tmp/unfinished-summary" >/dev/null \
  || fail 'unobserved interrupted-work count missing from retry summary'
"$summarizer" "$tmp/missing-boundary.jsonl" >"$tmp/incomplete-boundary-summary"
rg -F 'WARNING: incomplete or malformed invocation boundaries' \
  "$tmp/incomplete-boundary-summary" >/dev/null \
  || fail 'missing invocation-stop marker did not invalidate performance evidence'
"$summarizer" "$tmp/malformed-event.jsonl" >"$tmp/malformed-event-summary"
rg -F 'WARNING: malformed structured Nix events' \
  "$tmp/malformed-event-summary" >/dev/null \
  || fail 'malformed structured event did not invalidate performance evidence'
"$summarizer" "$tmp/boundary.jsonl" >"$tmp/boundary-summary"
rg -F 'Derivation Builds: 0 stopped, 1 still active at capture end' \
  "$tmp/boundary-summary" >/dev/null \
  || fail 'process-local activity ID crossed an invocation boundary'

printf '%s\n' 'Checking concurrent nested-Nix rejection while logging...'
cat >"$tmp/concurrent-wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
nix concurrency-hold &
first_pid=$!
deadline=$((SECONDS + 5))
while [[ ! -e ${CONCURRENCY_READY:?} ]] && (( SECONDS < deadline )); do
  sleep 0.001
done
[[ -e $CONCURRENCY_READY ]] || { kill "$first_pid"; wait "$first_pid"; exit 70; }
status=0
nix second || status=$?
: >"${CONCURRENCY_RELEASE:?}"
wait "$first_pid"
[[ $status == 75 ]] || exit "$status"
exit 0
EOF
chmod 700 "$tmp/concurrent-wrapper"
concurrent_status=0
CONCURRENCY_READY="$tmp/concurrency-ready" \
  CONCURRENCY_RELEASE="$tmp/concurrency-release" \
  PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/concurrent.jsonl" -- "$tmp/concurrent-wrapper" \
  >"$tmp/concurrent-stdout" 2>"$tmp/concurrent-stderr" \
  || concurrent_status=$?
[[ $concurrent_status == 75 ]] \
  || fail "expected concurrent-call status 75, got $concurrent_status"
rg -F 'concurrent nested Nix calls are unsupported while logging' \
  "$tmp/concurrent-stderr" >/dev/null \
  || fail 'concurrent-call diagnostic missing'

printf '%s\n' 'Checking rejection of descendants that retain the capture...'
cat >"$tmp/background-wrapper" <<EOF
#!/usr/bin/env python3
import os
import pathlib
import time

child = os.fork()
if child == 0:
    time.sleep(30)
    os._exit(0)
pathlib.Path("$tmp/background-pid").write_text(str(child))
EOF
chmod 700 "$tmp/background-wrapper"
background_status=0
PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/background.jsonl" -- "$tmp/background-wrapper" \
  >"$tmp/background-stdout" 2>"$tmp/background-stderr" \
  || background_status=$?
if [[ $background_status != 76 ]]; then
  <"$tmp/background-stderr" tail -50 >&2
  fail "expected background-descendant status 76, got $background_status"
fi
kill -0 "$(<"$tmp/background-pid")" 2>/dev/null \
  || fail 'capture handling killed a background service that had retained stderr'
kill -TERM "$(<"$tmp/background-pid")" 2>/dev/null || true
rg -F 'wrapper left background descendants holding the capture' \
  "$tmp/background-stderr" >/dev/null \
  || fail 'background-descendant diagnostic missing'

cat >"$tmp/detached-stderr-wrapper" <<EOF
#!/usr/bin/env python3
import os
import pathlib
import time

child = os.fork()
if child == 0:
    os.close(2)
    time.sleep(30)
    os._exit(0)
pathlib.Path("$tmp/detached-stderr-pid").write_text(str(child))
EOF
chmod 700 "$tmp/detached-stderr-wrapper"
detached_status=0
PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/detached-stderr.jsonl" -- "$tmp/detached-stderr-wrapper" \
  >"$tmp/detached-stderr-stdout" 2>"$tmp/detached-stderr-stderr" \
  || detached_status=$?
[[ $detached_status == 0 ]] \
  || fail "background service with closed stderr was rejected: $detached_status"
kill -0 "$(<"$tmp/detached-stderr-pid")" 2>/dev/null \
  || fail 'background service with closed stderr was killed'
kill -TERM "$(<"$tmp/detached-stderr-pid")" 2>/dev/null || true

printf '%s\n' 'Checking bounded drain for a daemonized stderr holder...'
cat >"$tmp/daemon-wrapper" <<EOF
#!/usr/bin/env bash
python3 -c 'import os,pathlib,time; os.setsid(); pathlib.Path("$tmp/daemon-pid").write_text(str(os.getpid())); pathlib.Path("$tmp/daemon-ready").touch(); time.sleep(30)' >&2 &
deadline=\$((SECONDS + 5))
while [[ ! -e "$tmp/daemon-ready" && \$SECONDS -lt \$deadline ]]; do sleep 0.01; done
[[ -e "$tmp/daemon-ready" ]]
EOF
chmod 700 "$tmp/daemon-wrapper"
daemon_status=0
PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/daemon.jsonl" -- "$tmp/daemon-wrapper" \
  >"$tmp/daemon-stdout" 2>"$tmp/daemon-stderr" || daemon_status=$?
[[ $daemon_status == 76 ]] \
  || fail "expected daemonized-descendant status 76, got $daemon_status"
jq -e 'select(.record == "command" and .event == "stop" and (.capture_healthy | not))' \
  "$tmp/daemon.jsonl" >/dev/null \
  || fail 'daemonized-descendant capture was not marked unhealthy'
kill -TERM "$(<"$tmp/daemon-pid")" 2>/dev/null || true

printf '%s\n' 'Checking signals targeted at the nested Nix shim...'
cat >"$tmp/nested-signal-wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
nix nested-signal &
printf '%s' "\$!" >"$tmp/nested-shim-pid"
wait "\$!"
EOF
chmod 700 "$tmp/nested-signal-wrapper"
nested_signal_status=0
NESTED_SIGNAL_READY="$tmp/nested-signal-ready" \
  PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/nested-signal.jsonl" -- "$tmp/nested-signal-wrapper" \
  >"$tmp/nested-signal-stdout" 2>"$tmp/nested-signal-stderr" &
nested_runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f $tmp/nested-signal-ready ]] && break
  sleep 0.1
done
[[ -f $tmp/nested-signal-ready ]] || fail 'nested Nix shim did not become ready'
kill -TERM "$(<"$tmp/nested-shim-pid")"
wait "$nested_runner_pid" || nested_signal_status=$?
[[ $nested_signal_status == 143 ]] \
  || fail "expected nested-shim signal status 143, got $nested_signal_status"
jq -e 'select(.record == "command" and .event == "stop" and .status == 143)' \
  "$tmp/nested-signal.jsonl" >/dev/null \
  || fail 'nested-shim signal was not propagated to the capture status'

printf '%s\n' 'Checking signal forwarding...'
cat >"$tmp/signal-wrapper" <<EOF
#!/usr/bin/env bash
trap 'printf received >"$tmp/signal-received"; exit 143' TERM
printf ready >"$tmp/signal-ready"
while :; do sleep 1; done
EOF
chmod 700 "$tmp/signal-wrapper"
signal_status=0
PATH="$tmp/fake-all:$PATH" "$runner" \
  --log-file "$tmp/signal.jsonl" -- "$tmp/signal-wrapper" &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f $tmp/signal-ready ]] && break
  sleep 0.1
done
[[ -f $tmp/signal-ready ]] || fail 'repository wrapper did not become ready'
kill -TERM "$runner_pid"
wait "$runner_pid" || signal_status=$?
[[ $signal_status == 143 ]] || fail "expected signal status 143, got $signal_status"
[[ -f $tmp/signal-received ]] || fail 'repository wrapper did not receive TERM'
jq -e 'select(.record == "command" and .event == "stop" and .status == 143)' \
  "$tmp/signal.jsonl" >/dev/null \
  || fail 'logging-mode signal capture did not finish with status 143'

printf '%s\n' 'Checking default signal status translation...'
cat >"$tmp/default-signal-wrapper" <<EOF
#!/usr/bin/env bash
printf ready >"$tmp/default-signal-ready"
exec sleep 30
EOF
chmod 700 "$tmp/default-signal-wrapper"
default_signal_status=0
PATH="$tmp/fake-all:$PATH" "$runner" -- "$tmp/default-signal-wrapper" &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  [[ -f $tmp/default-signal-ready ]] && break
  sleep 0.1
done
[[ -f $tmp/default-signal-ready ]] || fail 'default-signal wrapper did not become ready'
kill -TERM "$runner_pid"
wait "$runner_pid" || default_signal_status=$?
[[ $default_signal_status == 143 ]] \
  || fail "expected default signal status 143, got $default_signal_status"

printf '%s\n' 'PASS: nested Nix authentication and reporting safeguards'
