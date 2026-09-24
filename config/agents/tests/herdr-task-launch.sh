#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

skill=${TASK_LAUNCH_SKILL:?TASK_LAUNCH_SKILL is required}
contents=$(tr '\n' ' ' <"$skill" | tr -s '[:space:]' ' ')

require() {
  grep -F -- "$1" <<<"$contents" >/dev/null || {
    printf 'missing launcher contract: %s\n' "$1" >&2
    exit 1
  }
}

reject() {
  if grep -F -- "$1" <<<"$contents" >/dev/null; then
    printf 'obsolete launcher contract remains: %s\n' "$1" >&2
    exit 1
  fi
}

# Explicit, unambiguous Local selection and command routing.
require 'Require exactly one trailing placement clause'
require '`with base branch REF` clause is present, it must precede that trailing placement clause.'
require 'Do not interpret the word `local` elsewhere in a task title or description as placement.'
require 'Reject extra, multiple, conflicting, or incorrectly ordered placement clauses as ambiguous.'
require 'Never silently fall back between Local and a saved machine.'
require 'Run Herdr commands as `herdr ...`, never with'
require 'Run Herdr commands as `herdr --machine PROFILE ...`.'
require 'Do not use'
require 'SSH, a saved profile, or a remote shell for Local target repository preflight or launch mutation.'
require 'read-only global occupancy and duplicate checks'
require 'sole exception: they must still inspect enabled saved servers with `herdr --machine PROFILE`'
require '`timeout 30 herdr --machine PROFILE agent list`'
require 'whole-process bound for every saved-machine Herdr inventory call'

# Local ordinary-Git source and immutable identity rules.
require 'ordinary Git, including Local, starts from its non-linked default checkout'
require 'must be a direct child of the repository directory'
require 'Local is an'
require 'ordinary-Git path and must reject Canva Git/VFS'
require '`$HOME/work/owner/repo` rather than adapting it.'
require 'branch: exactly `jamesl/SLUG`'
require 'components match `^[A-Za-z0-9_.-]+$`'
require 'neither `.` nor `..`'
require 'beneath the canonical `$HOME/work` directory'
require '`COMMAND` must be a fixed script.'
require 'separately shell-quoted positional argument'
require 'Never concatenate dynamic values into shell source or use `eval`.'

# Cross-server allocation and duplicate/partial-state rejection remain mandatory.
require 'Animal occupancy is global client policy'
require 'inspect every enabled saved profile'
require 'Treat an exact case-sensitive name on any inspected server as occupied.'
require 'A matching or partial task'
require 'A repeated'
require 'Local request follows the same duplicate/partial-state stop'
require 'rerun `start-task` from a neutral Local workspace'
require 'do not create a second parent workspace for the same source.'

# Creation, prompt delivery, and Local focus are all explicit.
require 'workspace create --cwd SOURCE'
require 'worktree create --workspace PARENT --branch jamesl/SLUG --base BASE'
require 'herdr agent start ANIMAL --kind pi'
require 'herdr --machine SAVED_PROFILE agent start ANIMAL --kind pi'
require 'send one separate `agent prompt`'
require 'Keep the complete local task note verbatim first'
require 'For Local, run `herdr agent focus ANIMAL`'
require '`herdr --machine SAVED_PROFILE agent focus ANIMAL`'

# Saved-machine behavior and uncertain post-mutation handling are preserved.
require 'prefix every saved-machine call with `herdr --machine SAVED_PROFILE`'
require 'do not clean it'
require 'up or retry blindly'

reject 'Local launch is not enabled yet'
reject '`local` remains reserved'
reject '`local` is reserved'