# my-lisp Architecture Reference

Read before changing task packages, module boundaries, or task identity. Coding
conventions and review guardrails remain in `AGENTS.md`.

## Module Map

| Module | Purpose |
|--------|---------|
| `my-agent-catalogue.el` | Declares the generated `my/agent-machines` configuration contract and explicit reload command; no launch/runtime operations. |
| `my-agent-session.el` | Explicit human-operated task/ad hoc launches, disposable worktree creation, independent task model/thinking overrides, and clear failure reporting; no retained launch context, task lifecycle or automatic cleanup. |
| `my-task.el` | Shared task root, catalogue-backed note capture/default hints, template/skill choices, file predicate, capture/list keymap, and note-created hook. |
| `my-task-list.el` | Dired display, persisted epic/regex filters and sort direction, and scoped reverts. |

```text
my-task.el ── autoloads ──► my-task-list.el
init.el ── loads trusted generated configuration via ──► my-agent-catalogue.el
my-task.el ── consumes my/agent-machines declared by ──► my-agent-catalogue.el
my-agent-session.el ── consumes inventory from ──► my-agent-catalogue.el
my-agent-session.el ── starts fresh conversations through ──► agent-shell / Pi ACP
my-task-list.el subscribes to the note-created hook
```

## Boundaries

- Task notes are ordinary Denote Markdown files under `~/work/tasks/`, with
  optional epic subdirectories. Use native Denote identifiers and links.
- Task packages own capture, files, links, filtering, and sorting—not managed
  statuses, finish/discard, dependency parsing/check-off, Git or sessions.
  `my-agent-session.el` separately owns three explicit human launch commands:
  `my/agent-session-start-from-file` creates a worktree and submits a saved task;
  `my/agent-session-start-new-worktree` creates an ad hoc worktree; and
  `my/agent-session-start-in-directory` starts ad hoc in an exact chosen directory.
  They share Git/startup internals, with no dispatcher or task-list/Dired binding.
  Herdr/Herdsman retain their runtime lifecycle and
  orchestration. See `../../../docs/agent-session.md` for launch/failure policy.
- New captures retain the `todo` filename signature solely to match the existing
  default `==todo--` regex. There is no transition API or status validation.
- `skill` is optional downstream metadata. Capture always selects a repository,
  then writes `repo`, named `machine`, `model`, and `thinking`.
  Both capture forms prompt for machine when multiple destinations qualify,
  with no implicit/default choice, skipping the machine prompt when only one
  destination is eligible. Ordinary capture uses the Nix-generated agent catalogue's model/thinking defaults;
  prefix capture exposes those choices. Base ref is gathered by Herdsman or
  explicitly confirmed by the Emacs launcher; legacy task-file `base-ref`
  metadata is ignored. Thinking
  prompts even in ordinary capture when no supported default exists. Templates
  have no Dependencies section.
- The generated catalogue is the sole choice/default source; no separate inventory,
  Git calls, host probes, mutable Pi settings, or launch lifecycle are involved in capture.
  Missing configuration, unusable selections, and cancellation stop before creating the note. Listing
  and file identity remain independent of the catalogue.
- `my-agent-catalogue.el` declares `my/agent-machines` and its contract.
  Normal startup loads `emacs/agent-catalogue.el` as trusted executable config,
  setting an alist of names to machine plists with directories, repository
  records, and model defaults. Typed Nix options and generation tests own
  structural validation, not a duplicate Lisp schema. Capture uses the loaded
  value: after activation, explicitly run `my/agent-catalogue-reload` or restart
  Emacs. The generated config omits local-machine identity. The separate launcher
  consumes the same inventory for machine, repository and browsing choices.
  Task model/thinking hints independently override Pi defaults; absent fields
  send no override. Nix source composition lives outside task Lisp.
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
- Generated agent configuration contract/reload → `my-agent-catalogue.el`
- Explicit human-operated worktree/directory launches → `my-agent-session.el`
- Dired views, persisted filters, sort, and pinned-scope reverts → `my-task-list.el`
- Package configuration, templates, links, and file auto-revert → `my-emacs-denote.el`

Prefer removing unused helpers over compatibility layers. New packages or state
owners require a genuine boundary or second supported use.

## Identity

Denote identifiers survive ordinary title/signature renames. Resolve current
paths with native `denote-get-path-by-id`, not old cached paths, branch names, or
session/worktree metadata. Private helpers are not cross-module APIs.
