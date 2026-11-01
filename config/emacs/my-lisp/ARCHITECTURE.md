# my-lisp Architecture Reference

Read before changing task packages, module boundaries, or task identity. Coding conventions and review guardrails remain in `AGENTS.md`.

## Module Map

Configuration is authored in `../my-emacs.org` and tangled by Nix into ordinary startup files and `my-emacs-modules/`. This directory owns handwritten implementations, never generated package declarations. ERT suites are in `../tests/`. See `../../../docs/emacs-literate.md` for the generation workflow.

| Configuration library | Purpose |
|-----------------------|---------|
| `my-agent-shell.el` | Reference actions, transcript paths, quoting and GC predicates. |
| `my-agent-shell-notifications.el` | Audio provider and waiting-session tracking; Org owns its settings and registration. |
| `agent-shell-compose.el`, `agent-shell-compose-block-edit.el` | Reusable composer markup and separate source editing; retain their genuine cross-package deferred gates. |
| `my-completion.el` | Project annotations and Cape completion helpers. |
| `my-editing.el` | Stale-file policy, prose wrapping, Org and Markdown presentation functions. |
| `my-ui.el` | Theme/font helpers, writing-view effects and mode-line formatting. |
| `my-denote.el` | Note startup, first-save integration and deferred follow-up auto-refresh advice. |
| `my-languages.el`, `my-shells.el`, `my-remote.el` | Eglot, deferred shell PATH and remote inventory/connection helpers. |
| `my-excali.el`, `my-org-excali.el` | Drawing implementation and deferred Org/exporter integration. |
| `my-agent-catalogue.el` | Generated `my/agent-machines` configuration contract and explicit reload; no launch/runtime operations. |
| `my-agent-session.el` | Human-operated launches, worktree creation, saved-snapshot parsing, optional task overrides and failure reporting. |
| `my-denote-task.el` | Follow-up root and file predicate for task-only auto-refresh; no capture or catalogue dependency. |

```text
init.el ── loads trusted generated configuration via ──► my-agent-catalogue.el
my-agent-session.el ── consumes inventory from ──► my-agent-catalogue.el
my-agent-session.el ── starts fresh conversations through ──► agent-shell / Pi ACP
my-denote.el ── recognizes follow-up files through ──► my-denote-task.el
```

## Boundaries

- Most conversations start ad hoc in a new worktree. Follow-ups are optional ordinary Denote Org files under `~/work/docs/tasks/`, with optional subdirectories. There is no custom task capture command, template registration, automatic skill selection, task-list UI, or task lifecycle.
- `my-agent-session.el` owns three explicit human launch commands: `my/agent-session-start-from-file` creates a worktree and submits a saved brief; `my/agent-session-start-new-worktree` creates an ad hoc worktree; `my/agent-session-start-in-directory` starts ad hoc in an exact directory. They share Git/startup internals, without a dispatcher or global agent prefix map. The generated agent module autoloads the commands for `M-x`. Cleanup is a separate human-coordinated action, never launch rollback or task orchestration. See `../../../docs/agent-session.md`.
- Follow-up discovery accepts unsigned and legacy signed Denote Org filenames, recursively under the task root. Markdown notes remain available through ordinary Denote browsing/links, but are not launch candidates. Regular notes default to Org under `~/work/docs/`. Existing notes, signatures, metadata and dependency text are not migrated or treated as lifecycle state.
- Optional `skill`, `repo`, `machine`, `model` and `thinking` keywords live in a contiguous opening Org header. Parsing is case-insensitive, rejects duplicate title/launch fields, and ignores body lookalikes. The full saved snapshot is submitted unchanged; unsaved/stale visiting buffers block launch. Absent skill means no injected skill instruction; absent model/thinking hints leave Pi defaults intact. Repository/machine selection and base-ref confirmation remain human-operated; legacy `base-ref` metadata is ignored.
- `my-agent-catalogue.el` declares the trusted generated inventory contract. Typed Nix options and generation tests own structural validation, not a duplicate Lisp schema. Startup loads `emacs/agent-catalogue.el`; after deployment explicitly reload it or restart Emacs. The launcher consumes loaded inventory for repository/machine/directory choices. Note identity and browsing do not depend on it.
- Native Denote/Dired own file browsing, links, and mutations. There are no custom indexes, persisted filters, status transitions, dependency enforcement, or automatic note maintenance. Agents use supplied snapshots without locating inaccessible originals.
- Document-wide Denote configuration lives in `my-emacs.org`, generating `my-emacs-denote.el`. Note startup, deferred naming, and task-only auto-refresh implementation live in `my-denote.el`. `my-denote-task.el` recognizes the follow-up root independently of the broader Denote directory. Retain the existing refresh/debounce behavior for externally edited follow-up notes.

## Placement Guide

- Follow-up root and file identity → `my-denote-task.el`
- Generated agent configuration contract/reload → `my-agent-catalogue.el`
- Human-operated launches, saved snapshots and overrides → `my-agent-session.el`
- Package configuration, bindings, links and file auto-revert policy → `my-emacs.org`
- Denote startup and auto-revert implementation → `my-denote.el`

Prefer removing unused helpers over compatibility layers. New packages or state owners require a genuine boundary or second supported use. Private helpers are not cross-module APIs.
