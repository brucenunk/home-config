<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Denote Task Files

Task notes are ordinary files under `~/work/docs/tasks/`, optionally grouped into
subdirectories. Emacs provides capture, Denote links/identity, Dired file
management, and browsing—not task status, dependency enforcement, or an agent
lifecycle. A human may explicitly launch a fresh conversation through the three Emacs commands
described below; task capture itself performs no launch.

## Agent Task Context

A launcher-supplied task snapshot is sufficient context, including when the
agent runs on another machine. Its provenance path and Denote links do not imply
that the original note is accessible there. Do not try to locate the original
note or resolve its Denote identifiers as a bootstrap step. If an explicitly
requested note edit requires access you do not have, ask the local owner rather
than creating or editing a substitute.

## Creating a Note

When the user says “task,” default to a Denote note. Create one through
`my/denote-task` in Emacs, or create a Markdown file under `~/work/docs/tasks/` using
Denote's naming convention:

```text
{identifier}--{title-slug}.md
```

- **identifier**: `YYYYMMDDTHHMMSS`, matching the note's identifier field.
- **title-slug**: lowercase with hyphens for spaces.
- New captures have no signature. Existing signed Denote Markdown filenames
  remain valid; signatures are ordinary organisation, not managed status.

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

`C-c n T` (`my/denote-task`) asks for an optional epic/subdirectory, title, and
repository and, when multiple destinations qualify, machine. It uses
`task-workflow-v3` and the shared catalogue's model and thinking defaults.
`C-u C-c n T` additionally offers skill
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
above. Machine values are catalogue keys, not display labels. Capture neither
prompts for nor writes `base-ref`; the Emacs launcher confirms it at launch,
defaulting to the repository's catalogue value (`origin/${defaultBranch}`).

Emacs startup loads `$XDG_CONFIG_HOME/emacs/agent-catalogue.el` (normally
`~/.config/emacs/agent-catalogue.el`) as trusted executable configuration,
setting `my/agent-machines`. Nix generates it from the shared machine inventory; it includes
machine browsing directories and machine-local repository paths/base refs, but
no local-machine identity. Capture uses this loaded value, not a fresh disk
read. After activating inventory changes, run `M-x my/agent-catalogue-reload`
or restart Emacs. Missing configuration or unusable
required choices stop capture with an actionable error; cancellation creates no
note. Browsing and existing notes do not require the catalogue. The catalogue
does not implement an Emacs session launcher.

These fields are optional launch hints, not launch authorization. The
human-operated Emacs commands below own launch choices and resolution. Capture
neither checks live Git refs nor probes hosts or changes running Pi settings.
Existing or manually authored notes may omit hints; legacy `base-ref` metadata
is ignored. Capture does not migrate or automatically change existing notes.

## Human-operated Emacs Launches

There are three explicit commands, separate from capture, with no combined
selector, dispatcher or compatibility alias:

- `M-x my/agent-session-start-from-file`: styled completion of Denote
  Markdown task notes recursively under `~/work/docs/tasks/`, including epics.
  Saved front-matter titles (with filename fallback) and repository/machine
  annotations describe candidates. Colliding titles gain relative-path suffixes
  so each file is selectable. Use a valid repository hint or ask,
  select an eligible machine, confirm the base ref and create a new worktree.
  Its optional Lisp `FILE` argument bypasses completion, not task validation.
- `M-x my/agent-session-start-new-worktree`: select a repository, then eligible
  machine, confirm the base ref and create a new ad hoc worktree.
- `M-x my/agent-session-start-in-directory`: select a machine, then browse from
  its configured directory and start ad hoc in the exact selected directory.
  It creates no worktree.

These commands do not manage task statuses or other agents. All choices precede
Git mutation or agent startup. Ad hoc sessions have no initial prompt, overrides
or description/name/model/thinking questions.

For a worktree, a valid task `repo` hint skips repository selection. One eligible
machine is automatic; multiple machines always require explicit selection with
no default, regardless of task `machine` hints or locality. The base ref is
always confirmed, defaulting to the catalogue value. New worktrees are siblings
of the configured repository source, not reconstructed from repository names.
Directory browsing starts at the machine's configured directory and the exact
chosen directory is retained as the agent CWD.

Local and remote transcripts are uniquely named Markdown files directly under
`~/work/agent-shell/transcripts/` on the Emacs host. Identifying metadata stays
in agent-shell's normal header; no transcript directories or Git exclusions are
created inside worktrees. Existing transcripts/worktrees are left untouched.

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

Use ordinary Denote/Dired commands to open, edit, rename, move, or delete
files. Regular Denote notes default to `~/work/docs/`; task capture and launcher
discovery use its `tasks/` subtree recursively. Denote links resolve across the
whole document tree. There is no custom task list or `C-c t` prefix.
There are no Emacs finish/discard commands, status transitions, dependency
parsers, or automatic edits to other notes.

Existing notes, including legacy signatures, `repo`/session metadata, and
Dependencies sections, are not migrated. Such content is ordinary file content.
File operations never stop agents, deliver code, remove branches, or release
worktrees. Session/worktree cleanup is a separate human-coordinated action;
agents must not automatically remove worktrees or branches. Repository delivery
follows the applicable repository guidance, separately from note management.
