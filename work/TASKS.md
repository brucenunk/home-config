<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Denote Task Files

Task notes are ordinary files under `~/work/tasks/`, optionally grouped into
subdirectories. Emacs provides capture, Denote links/identity, Dired file
management, and filtering—not task status, dependency enforcement, or an agent
lifecycle. Herdr/Herdsman own agent-operated sessions/worktrees. A human may
explicitly launch a fresh conversation and optional disposable worktree with
Emacs's `my/agent-session-start`; task capture itself performs no launch.

## Identity and Resolution

Denote links use stable identifiers, for example `denote:20260129T180405`.
Resolve an identifier to its current path when needed:

```bash
emacsclient -e '(denote-get-path-by-id "IDENTIFIER")'
```

This returns a full path or `nil`. Do not infer identity from a title, agent
session, repository, branch, or worktree name.

## Creating a Note

When the user says “task,” default to a Denote note. Create one through
`my/task-add` in Emacs, or create a Markdown file under `~/work/tasks/` using
Denote's naming convention:

```text
{identifier}==todo--{title-slug}.md
```

- **identifier**: `YYYYMMDDTHHMMSS`, matching the note's identifier field.
- **title-slug**: lowercase with hyphens for spaces.
- **`todo` signature**: retained as a filename convention so new captures match
  the existing default `==todo--` list filter. It is not a managed status.
  Other Denote names/signatures remain valid; use a different regex to show them.

## New Note Template

```markdown
---
title:      "task title"
date:       2026-03-04T15:32:50+11:00
tags:       []
identifier: "20260304T153250"
skill:      task-workflow-v3
repo:       "example/project"
machine:    "machine-a"
model:      "example-provider/vendor/model"
thinking:   "medium"
---

## Context

Initial thoughts, background, and links for future pickup.

## Goals

-

## Non-Goals

-

## Constraints

- Durable constraints, locked details, or invariants that should survive session handoff.
```

Fill the note with useful bootstrap context rather than leaving placeholders:
why it exists, desired outcome, current state, relevant files/commands/links,
boundaries, and the intended verification target. For a note spawned from other
work, link to that source and summarize the context; the link is ordinary prose,
not an enforced or automatically checked-off dependency.

The launch-hint values above are illustrative; use the generated catalogue and
the intended repository/destination, not these example values.

`skill` is optional metadata for downstream consumers. Use `task-workflow-v3`
for scope alignment, autonomous implementation/verification/review, and a
review-ready handoff. Named capture choices such as `bump-nix` set that skill;
`none` creates an empty body without skill metadata, while retaining capture's
launch hints.

## Capture Choices and Launch Hints

`C-c t a` (`my/task-add`) asks for an optional epic/subdirectory, title, and
repository and, when multiple destinations qualify, machine. It uses
`task-workflow-v3` and the shared catalogue's model and thinking defaults.
`C-u C-c t a` additionally offers skill
selection and the capture hints in this order:

1. Repository (always selected explicitly).
2. Machine (eligible destinations for that repository; skip with one choice).
3. Model (`provider/model`, with additional slashes preserved in the model ID).
4. Thinking (only levels supported by that model).

Both capture forms require an explicit machine choice with no default when
multiple destinations qualify. A sole eligible machine is selected automatically;
the machine running Emacs has no preference. The model uses the selected machine's effective default.
Thinking defaults to `medium` when supported, otherwise `off`; if neither is
supported, even ordinary capture asks for an explicit supported choice.

Every captured value is written after `skill` in front matter, in the order
above. Machine values are catalogue keys, never the display label `Local` or
routing key `local`. Capture neither prompts for nor writes `base-ref`;
Herdsman gathers it at launch, defaulting to `origin/${defaultBranch}`.

Emacs startup loads `$XDG_CONFIG_HOME/emacs/agent-catalogue.el` (normally
`~/.config/emacs/agent-catalogue.el`) as trusted executable configuration,
setting `my/agent-machines`. Nix generates it from the shared machine inventory; it includes
machine browsing directories and machine-local repository paths/base refs, but
no local-machine identity. Capture uses this loaded value, not a fresh disk
read. After activating inventory changes, run `M-x my/agent-catalogue-reload`
or restart Emacs. Missing configuration or unusable
required choices stop capture with an actionable error; cancellation creates no
note. Listing and existing notes do not require the catalogue. The catalogue
does not implement an Emacs session launcher.

These fields remain optional hints to Herdsman, not launch authorization.
Herdsman skips a usable repository hint and an eligible local machine hint;
remote destinations, model, thinking, and base ref still require confirmation.
Missing/unavailable hints require selection or deliberate replacement, and
back-navigation can revisit skipped choices. Herdsman owns final selection and
local/remote resolution. Emacs neither checks live Git refs nor probes hosts or
changes running Pi settings. Existing or manually authored notes may omit hints;
legacy `base-ref` metadata is ignored. Capture does not migrate or automatically
change existing notes.

## Human-operated Emacs Launches

`M-x my/agent-session-start` has exactly two entry modes: select a saved task
file with YAML front matter, or start ad hoc without a task or initial prompt.
Both can create a fresh repository worktree or use an existing directory.
This is separate from capture and does not manage task statuses or other agents.

For a worktree, a valid task `repo` hint skips repository selection. One eligible
machine is automatic; multiple machines always require explicit selection with
no default, regardless of task `machine` hints or locality. The base ref is
always confirmed, defaulting to the catalogue value. New worktrees are siblings
of the configured repository source, not reconstructed from repository names.
Directory browsing starts at the machine's configured directory and the exact
chosen directory is retained as the agent CWD.

Task `model` and `thinking` fields are independent optional overrides, applied
without confirmation before sending context. An absent field sends no override;
Pi keeps its configured default. Unsupported values stop automatic submission.
Ad hoc sessions send neither override and ask no configuration questions.
Emacs sends a complete saved task snapshot and, when present, its declared skill
instruction. Remote agents need not read the original local path; provenance
does not imply that path is accessible or editable remotely.

Failures report the retained directory and shell buffer when available; nothing
is automatically deleted or resent. Inspect partial Git operations and uncertain
prompt delivery manually. Open the retained directory and start agent-shell
normally when ready. There is no retained retry context, special recovery UI,
automatic cleanup or agent-to-agent control.

## Managing Files

Open the task list with `my/task-list`. Use epic/regex filters and identifier
sorting, and ordinary Denote/Dired commands to open, edit, rename, move, or delete
files. There are no Emacs finish/discard commands, status transitions, dependency
parsers, or automatic edits to other notes.

Existing notes, including legacy signatures, `repo`/session metadata, and
Dependencies sections, are not migrated. Such content is ordinary file content.
File operations never stop agents, deliver code, remove branches, or release
worktrees. Follow the current Herdr/Herdsman and repository guidance separately
for those actions.
