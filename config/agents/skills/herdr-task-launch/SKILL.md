---
name: herdr-task-launch
description: "Launch a Denote task as a durable Pi agent in a semantic Herdr worktree. Use only for a one-shot start-task coordinator request from a Local Herdr pane. Resolves the canonical local note, preflights saved-machine and repository state, and either launches once or stops safely with clarification or recovery guidance."
---

# Herdr Task Launch

You are a one-shot coordinator. Resolve one canonical local Denote task, launch
its durable Pi agent through Herdr, report the result, and exit. Never create a
coordinator workspace, pane, agent name, or Pi session.

Running `start-task` is intent to launch the one task unambiguously selected by
the request. It is not permission to repair/delete conflicting state, stop an
agent/server, alter the task note, or guess. Print-mode clarification cannot
continue: on ambiguity, make no mutation and return at most five candidates
plus an exact rerun such as:

```sh
start-task "Start task 20260918T162459 on devbox"
start-task "Start task 20260918T162459 on devbox with base branch release/train"
```

The matching human-facing lifecycle commands are deliberately small:

```text
start-task "<task request>"
finish-task <animal>
```

## 1. Establish context

Require `HERDR_ENV=1`, `HERDR_WORKSPACE_ID`, `HERDR_PANE_ID`, and a live local
`HERDR_SOCKET_PATH`. Run `herdr status` and `herdr pane current --current`.
Require `command -v timeout` for bounded SSH probes. Stop if this is not a
compatible Local Herdr context. Run `herdr --skill`, read it completely, and
follow it. The installed 0.9.1 CLI is authoritative;
`herdr --machine <saved-label> ...` is the confirmed saved-machine interface.
Parse all IDs from command JSON rather than predicting them.

## 2. Resolve the local task

Tasks under `$HOME/work/tasks` are canonical. Accept an identifier, unique
title/Jira key, or sufficiently specific description. Validate an identifier
against `^[0-9]{8}T[0-9]{6}$` before resolving it with:

```sh
emacsclient -e '(denote-get-path-by-id "IDENTIFIER")'
```

For semantic lookup, search task Markdown recursively and inspect plausible
notes. Require one active `==todo--` note and read it completely. If ambiguous,
return `identifier — title` candidates without using hidden `fzf` UI.

Read `title`, `identifier`, `repo`, and `skill` from simple frontmatter. Use a
valid `owner/repo` value. If repository metadata is absent, invalid, or absent
on the selected machine, require an explicit `owner/repo` in the request; never
guess or rewrite the note. Keep the complete note verbatim. Do not parse or
enforce dependencies.

## 3. Select machine and repository

Use the explicitly requested saved machine, otherwise `devbox`. Resolve exactly
one enabled case-sensitive label from `herdr machine list --json`, retaining its
profile selector and OpenSSH target. `local` is reserved for the downstream
local migration and is not enabled by this skill yet.

Use system OpenSSH for simple host/Git probes so configured host-key,
ProxyCommand, agent, Roo, Teleport, and forwarding policy remain authoritative:

```sh
timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=15 TARGET COMMAND
```

Use this whole-process bound for every SSH probe. Authentication failure or
timeout is an uncertain read-only failure: stop without mutation or retry.
Obtain remote `$HOME`, user, and `command -v git`, `pi`, and `herdr`. Invoke the
returned host-selected Git; Canva hosts must continue through canva-git.

Require the repository at `$HOME/work/owner/repo`. Discover its default branch
and non-linked source using Git metadata and `git worktree list --porcelain`:

- ordinary Git starts from its non-linked default checkout (`main`/`master`);
- Canva Git/EdenFS starts from the bare `<default>.git` backing repository,
  such as `master.git`, never linked `master`.

Do not fetch, repair, trust, clean, or mutate Git during preflight. Stop when
repository identity, source, or base is not clear.

The request may name one exact base branch/ref for a PR train. When omitted,
use the verified default branch. Resolve an explicit base only from
`refs/heads/*` or an already-present `refs/remotes/*`: validate it as a branch,
require exactly one match when a short name is used, and resolve its commit
before mutation. Reject tags, commit-only values, missing/ambiguous refs, and
anything requiring fetch or guessing. Record the selected branch/ref and commit
as the intended PR base; never rebase or retarget a train automatically.

## 4. Name and preflight the launch

Derive these identities deterministically from canonical title text so every
coordinator proposes the same values for the same task. Split the title into
ASCII alphanumeric tokens, lowercase them, and join them with hyphens for the
slug; do not drop generic words. If it exceeds 48 characters, cut only at the
last complete token that fits. Stop if this produces no clear slug.

- parent workspace: exact `owner/repo`;
- task workspace: exact full title when it fits 48 characters, otherwise the
  deterministic whole-word prefix that fits, retaining a leading Jira key;
- Pi session: exact full task title;
- worktree slug: normalized title matching
  `^[a-z0-9]+(-[a-z0-9]+)*$`;
- worktree path: `$HOME/work/owner/repo/SLUG`;
- branch: exactly `jamesl/SLUG`, so its suffix exactly equals the path leaf.

Choose the first unused live agent name from this pool, preserving an existing
task animal when plainly discoverable:

```text
bushturkey binchicken possum quokka wallaby wombat bilby numbat
kookaburra echidna platypus cockatoo
```

Prefer a bare animal. Add a short Jira/slug disambiguator only if every bare
name is occupied, and keep Herdr's `[a-z][a-z0-9_-]{0,31}` constraint.

Animal occupancy is global client policy even though Herdr names are scoped per
server. Before selecting a name, parse `herdr machine list --json`, inspect the
Local server, and inspect every enabled saved profile with
`herdr --machine PROFILE agent list` and `workspace list`. Use the saved profile
ID as the selector and retain its meaningful label for diagnostics. Any
connection failure, timeout, invalid JSON, or incompatible enabled server makes
occupancy unknown: stop before mutation rather than allocating a name. Treat an
exact case-sensitive name on any inspected server as occupied.

Search those same inventories for an existing assignment to this exact task
workspace/path before selecting a fresh animal. Preserve its name when there is
one unambiguous matching Pi; conflicting or partial state still stops under the
recovery rules below. This preservation does not authorize reuse of an animal
from another task or bypass the requirement that a new assignment be globally
unused.

Before mutation, inspect the cross-server `workspace list`/`agent list`
inventories described above and the target host Git state.
Check exact conflicts for the proposed parent source, task workspace label,
branch, worktree path/registration, and animal. A matching or partial task
state must stop with useful recovery/select-existing guidance. A repeated
request must not create another workspace, pane, branch, worktree, or agent.

### Continue a trust-blocked launch

Use this recovery path only when a later request explicitly asks to continue
the same task after the human resolved Pi project trust. Recompute the canonical
names and require exact machine, repository, path, branch, and task-workspace
matches, with exactly one existing Pi in that workspace. Any mismatch,
duplicate, missing agent, or ambiguity stops without input.

Inspect that Pi with `agent get` and a bounded `agent read`, including its
reported Pi session identity, only enough to determine whether the task prompt
is absent or already present. If that cannot be proved, stop. If still blocked,
report the UI for human action. If idle/done and the prompt is absent, send the
verbatim note and bootstrap instruction exactly once, then focus. If the prompt
is already present, send nothing; only focus and report. Never create or reuse
other state through this recovery path.

## 5. Launch in order

After preflight succeeds, serialize these Herdr calls and prefix every remote
call with `herdr --machine SAVED_PROFILE`:

1. Reuse the one parent workspace for the source. Rename it to exact
   `owner/repo` when needed, or create it with `workspace create --cwd SOURCE
   --label owner/repo --no-focus`. Parse its ID from JSON.
2. Run `worktree create --workspace PARENT --branch jamesl/SLUG --base BASE
   --path ABSOLUTE_PATH --label TASK_LABEL --no-focus`. Parse the new workspace
   and root pane IDs from `.result.workspace` and `.result.root_pane`.
3. Start idle Pi without an initial prompt:

   ```sh
   herdr --machine SAVED_PROFILE agent start ANIMAL --kind pi \
     --pane PANE --timeout 120000 -- --name "FULL TASK TITLE"
   ```

   Do not force `--approve` or `--no-approve`. Normal Pi project trust may leave
   the new agent blocked after creation; inspect and report that dialog for the
   human instead of answering it or starting another agent.
4. Only after Pi is idle/done, send one separate `agent prompt`. Keep the
   complete local task note verbatim first, then construct an instruction with
   the exact parsed `skill` value, for example: `The task frontmatter declares
   workflow skill task-workflow-v3. Load the task-workflow-v3 skill and follow
   its instructions. Recenter from this worktree and the supplied note. Do not
   claim to edit or finish a canonical note unavailable on this machine.` Do
   not pass the workflow through Pi `--skill`; its remote path is machine-owned
   and normal global discovery must resolve the declared name. If unavailable,
   the target agent reports that failure; the coordinator does not implement
   exhaustive remote skill discovery. Append: `Intended PR base: BASE (COMMIT).
   Preserve this base for later pull-request delivery; do not rebase or retarget
   the train automatically.` Substitute the exact preflighted branch/ref and
   commit.
5. Focus the animal when supported. A saved-machine focus may not switch the
   local multi-machine client; if not, say `Select MACHINE → TASK_WORKSPACE in
   Herdr.`

On any post-mutation error, report exactly what was created and do not clean it
up or retry blindly. On success, report task, machine, parent/task workspaces,
animal, path, branch, and focus result without routine opaque IDs.