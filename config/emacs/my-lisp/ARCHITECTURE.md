# my-lisp Architecture Reference

Read before changing task packages, module boundaries, or task identity. Coding
conventions and review guardrails remain in `AGENTS.md`.

## Module Map

| Module | Purpose |
|--------|---------|
| `my-agent-catalogue.el` | Declares the generated `my/agent-machines` configuration contract and explicit reload command; no launch/runtime operations. |
| `my-agent-session.el` | Explicit human-operated task/ad hoc launches, disposable worktree creation, independent task model/thinking overrides, and clear failure reporting; no retained launch context, task lifecycle or automatic cleanup. |
| `my-denote-task.el` | Task root, catalogue-backed `my/denote-task` capture/default hints, template/skill choices, and task-file predicate. |

```text
init.el ── loads trusted generated configuration via ──► my-agent-catalogue.el
my-denote-task.el ── consumes my/agent-machines declared by ──► my-agent-catalogue.el
my-agent-session.el ── consumes inventory from ──► my-agent-catalogue.el
my-agent-session.el ── starts fresh conversations through ──► agent-shell / Pi ACP
```

## Boundaries

- New task notes are ordinary Denote Org files under `~/work/docs/tasks/`, with
  optional epic subdirectories. Use native Denote identifiers and links.
  Capture and human task launches support Org only; existing Markdown files
  remain untouched and available through ordinary Denote browsing and links.
  Launch metadata uses literal single-line `#+skill:`, `#+repo:`, `#+machine:`,
  `#+model:` and `#+thinking:` keywords in a contiguous opening header ending
  with a blank line. Launcher parsing is case-insensitive and rejects duplicate
  title/launch fields; body keywords never supply launch metadata.
- The capture package owns task files and metadata—not managed
  statuses, finish/discard, dependency parsing/check-off, Git or sessions.
  `my-agent-session.el` separately owns three explicit human launch commands:
  `my/agent-session-start-from-file` creates a worktree and submits a saved task;
  `my/agent-session-start-new-worktree` creates an ad hoc worktree; and
  `my/agent-session-start-in-directory` starts ad hoc in an exact chosen directory.
  They share Git/startup internals, with no dispatcher. `init.el` binds the global
  `C-c a f` to the file launcher's normal task picker. Saved-snapshot validation and all launch choices,
  operations and failure handling remain with the launcher; capture remains file-only.
  Session/worktree cleanup remains a separate human-coordinated action, not
  agent orchestration. See `../../../docs/agent-session.md` for launch/failure policy.
- Regular Denote notes default to Org under `~/work/docs/`; task capture and discovery
  are scoped to its `tasks/` subtree. New captures have no filename signature;
  discovery also accepts existing signed Denote Org notes. There is no
  transition API or status validation. `C-c n T` invokes `my/denote-task`; the
  old task prefix and custom task-list UI are removed.
- `skill` is optional downstream metadata. Capture always selects a repository,
  then writes `repo`, named `machine`, `model`, and `thinking`.
  Both capture forms prompt for machine when multiple destinations qualify,
  with no implicit/default choice, skipping the machine prompt when only one
  destination is eligible. Ordinary capture uses the Nix-generated agent catalogue's model/thinking defaults;
  prefix capture exposes those choices. Base ref is explicitly confirmed by
  the Emacs launcher; legacy task-file `base-ref`
  metadata is ignored. Thinking
  prompts even in ordinary capture when no supported default exists. Templates
  have no Dependencies section.
- The generated catalogue is the sole choice/default source; no separate inventory,
  Git calls, host probes, mutable Pi settings, or launch lifecycle are involved in capture.
  Missing configuration, unusable selections, and cancellation stop before creating the note. Browsing
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
- Native Denote/Dired handle file browsing and mutations. There is no custom
  task list, persisted filter state, task index, active/WIP highlighting, git
  recovery, or lifecycle notification system.
- Task-file auto-refresh and document-wide Denote configuration live in
  `my-emacs-denote.el`. The task predicate checks the task root independently
  of the broader Denote document root. Configured note templates use Org.

## Placement Guide

- Note capture, task root, templates, catalogue/default hints, skill metadata,
  and task-file predicate → `my-denote-task.el`
- Generated agent configuration contract/reload → `my-agent-catalogue.el`
- Explicit human-operated worktree/directory launches → `my-agent-session.el`
- Package configuration, templates, links, and file auto-revert → `my-emacs-denote.el`

Prefer removing unused helpers over compatibility layers. New packages or state
owners require a genuine boundary or second supported use.

## Identity

Denote identifiers survive ordinary title/signature renames; Emacs owns local
link resolution. Agents consume the launcher-supplied snapshot without needing
access to the original note or its Denote directory. Private helpers are not
cross-module APIs.
