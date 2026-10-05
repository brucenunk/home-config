<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Denote Task Files

Task notes are ordinary files under `~/work/tasks/`, optionally grouped into
subdirectories. Emacs provides capture, Denote links/identity, Dired file
management, and filtering—not task status, dependency enforcement, or an agent
lifecycle. Herdr/Herdsman select the repository and own sessions/worktrees.

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
base-ref:   "origin/main"
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
repository. It uses `task-workflow-v3` and the shared catalogue's destination,
base-ref, model, and thinking defaults. `C-u C-c t a` additionally offers skill
selection and the launch choices in Herdsman's order:

1. Repository (always selected explicitly).
2. Machine (eligible destinations for that repository; skip with one choice).
3. Base ref (free text, initially `origin/${defaultBranch}` for that destination).
4. Model (`provider/model`, with additional slashes preserved in the model ID).
5. Thinking (only levels supported by that model).

The default destination is the local named machine when eligible, otherwise the
first named eligible destination. The model uses that machine's effective default.
Thinking defaults to `medium` when supported, otherwise `off`; if neither is
supported, even ordinary capture asks for an explicit supported choice.

Every captured value is written after `skill` in front matter, in the order
above—including the accepted base-ref default. Machine values are catalogue
keys, never the display label `Local` or routing key `local`. A base-ref override
is written exactly: another remote's branch, a local branch, or a PR-train ref
does not receive an automatic `origin/` prefix.

Capture reads `$XDG_CONFIG_HOME/herdsman/catalogue.json` (falling back to
`~/.config/herdsman/catalogue.json`). Missing/invalid catalogue data or unusable
required choices stop capture with an actionable error; cancellation creates no
note. Listing and existing notes do not require the catalogue.

These fields remain optional defaults to Herdsman, not launch authorization.
Herdsman owns final repository/destination/model/thinking/ref selection and
local/remote resolution. Emacs neither checks live Git refs nor probes hosts or
changes running Pi settings. Existing or manually authored notes may omit hints;
removing `base-ref` lets Herdsman use `origin/${defaultBranch}` at launch. Capture
does not migrate or automatically change existing notes.

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
