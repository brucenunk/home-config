#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bump-nix-discovery.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/project/.agents/skills" "$tmp/project/tasks" \
  "$tmp/home" "$tmp/agent/skills/bump-nix" "$tmp/project/nested"
cp -R "$repo_root/.agents/skills/bump-nix" "$tmp/project/.agents/skills/"
cat >"$tmp/agent/skills/bump-nix/SKILL.md" <<'EOF'
---
name: bump-nix
description: Conflicting deployed global bump skill used only by this test.
---

# Wrong global skill
EOF
cat >"$tmp/project/tasks/representative-bump.md" <<'EOF'
---
title: Representative bump
repo: brucenunk/home-config
skill: bump-nix
---
EOF
git -C "$tmp/project" init -q
expected_path=$(cd "$tmp/project/.agents/skills/bump-nix" && pwd -P)/SKILL.md

response=$(
  cd "$tmp/project/nested"
  printf '%s\n' '{"id":"commands","type":"get_commands"}' |
    HOME="$tmp/home" PI_CODING_AGENT_DIR="$tmp/agent" \
      pi --mode rpc --no-session --offline --approve \
      --no-extensions --no-prompt-templates --no-themes 2>"$tmp/pi-stderr"
)

jq -e --arg expected "$expected_path" '
  select(
    .type == "response"
    and .command == "get_commands"
    and .success == true
  )
  | [
      .data.commands[]
      | select(
          .name == "skill:bump-nix"
          and .source == "skill"
          and .sourceInfo.scope == "project"
          and .sourceInfo.source == "auto"
          and .sourceInfo.path == $expected
        )
    ]
  | length == 1
' <<<"$response" >/dev/null

printf '%s\n' 'PASS: Pi preferred the project-local bump-nix skill over a global copy'
