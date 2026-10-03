# my-lisp Architecture Reference

Read before changing task packages, module boundaries, or task identity. Coding
conventions and review guardrails remain in `AGENTS.md`.

## Module Map

| Module | Purpose |
|--------|---------|
| `my-task.el` | Shared task root, note capture, template/skill choices, file predicate, capture/list keymap, and note-created hook. |
| `my-task-list.el` | Dired display, persisted epic/regex filters and sort direction, and scoped reverts. |

```text
my-task.el ── autoloads ──► my-task-list.el
my-task-list.el subscribes to the note-created hook
```

## Boundaries

- Task notes are ordinary Denote Markdown files under `~/work/tasks/`, with
  optional epic subdirectories. Use native Denote identifiers and links.
- Emacs owns capture, files, links, filtering, and sorting—not managed statuses,
  finish/discard, dependency parsing/check-off, repositories, git, worktrees, or
  agent sessions. Herdr/Herdsman own repository selection and runtime lifecycle.
- New captures retain the `todo` filename signature solely to match the existing
  default `==todo--` regex. There is no transition API or status validation.
- `skill` is optional downstream metadata. Capture never prompts for a repository
  or writes a `repo` field. Templates have no Dependencies section.
- Existing notes are untouched, including legacy signatures, repo/session fields,
  and dependency text. These are ordinary content, not runtime state.
- A saved capture runs `my/task-note-created-hook` to refresh open task lists.
  Native Denote/Dired handle other file mutations. There is no task index,
  active/WIP highlighting, git recovery, or lifecycle notification system.
- Ordinary task-file auto-refresh and Denote configuration live in
  `my-emacs-denote.el`. List buffers pin their scope so reverts and cloned views
  preserve filtering without disturbing the window layout.

## Placement Guide

- Note capture, shared root, templates, skill metadata, capture/list bindings,
  and task-file predicate → `my-task.el`
- Dired views, persisted filters, sort, and pinned-scope reverts → `my-task-list.el`
- Package configuration, templates, links, and file auto-revert → `my-emacs-denote.el`

Prefer removing unused helpers over compatibility layers. New packages or state
owners require a genuine boundary or second supported use.

## Identity

Denote identifiers survive ordinary title/signature renames. Resolve current
paths with native `denote-get-path-by-id`, not old cached paths, branch names, or
session/worktree metadata. Private helpers are not cross-module APIs.
