# my-lisp Architecture Reference

Read before changing task packages, module boundaries, or task identity. Coding
conventions and review guardrails remain in `AGENTS.md`.

## Module Map

| Module | Purpose |
|--------|---------|
| `my-task.el` | Shared task root, catalogue-backed note capture/default hints, template/skill choices, file predicate, capture/list keymap, and note-created hook. |
| `my-task-list.el` | Dired display, persisted epic/regex filters and sort direction, and scoped reverts. |

```text
my-task.el ── autoloads ──► my-task-list.el
my-task-list.el subscribes to the note-created hook
```

## Boundaries

- Task notes are ordinary Denote Markdown files under `~/work/tasks/`, with
  optional epic subdirectories. Use native Denote identifiers and links.
- Emacs owns capture, files, links, filtering, and sorting—not managed statuses,
  finish/discard, dependency parsing/check-off, git, worktrees, or
  agent sessions. Herdr/Herdsman own repository selection and runtime lifecycle.
  Emacs authors launch hints; it does not validate reachability or authorize launch.
- New captures retain the `todo` filename signature solely to match the existing
  default `==todo--` regex. There is no transition API or status validation.
- `skill` is optional downstream metadata. Capture always selects a repository,
  then writes `repo`, named `machine`, exact `base-ref`, `model`, and `thinking`.
  Ordinary capture uses the Nix-generated Herdsman catalogue defaults. Prefix
  capture exposes machine/base-ref/model/thinking choices in Herdsman's order,
  skipping the machine prompt when only one destination is eligible. Thinking
  prompts even in ordinary capture when no supported default exists. Templates
  have no Dependencies section.
- The generated catalogue is the sole choice/default source; no cached inventory,
  Git calls, host probes, mutable Pi settings, or launch lifecycle are involved.
  Invalid/missing data and cancellation stop before creating the note. Listing
  and file identity remain independent of the catalogue.
- Existing notes are untouched, including legacy signatures, repo/session fields,
  and dependency text. These are ordinary content, not runtime state.
- A saved capture runs `my/task-note-created-hook` to refresh open task lists.
  Native Denote/Dired handle other file mutations. There is no task index,
  active/WIP highlighting, git recovery, or lifecycle notification system.
- Ordinary task-file auto-refresh and Denote configuration live in
  `my-emacs-denote.el`. List buffers pin their scope so reverts and cloned views
  preserve filtering without disturbing the window layout.

## Placement Guide

- Note capture, shared root, templates, catalogue/default hints, skill metadata, capture/list bindings,
  and task-file predicate → `my-task.el`
- Dired views, persisted filters, sort, and pinned-scope reverts → `my-task-list.el`
- Package configuration, templates, links, and file auto-revert → `my-emacs-denote.el`

Prefer removing unused helpers over compatibility layers. New packages or state
owners require a genuine boundary or second supported use.

## Identity

Denote identifiers survive ordinary title/signature renames. Resolve current
paths with native `denote-get-path-by-id`, not old cached paths, branch names, or
session/worktree metadata. Private helpers are not cross-module APIs.
