# my-lisp Architecture Reference

Read this document before changing task-system packages, agent backends, module boundaries, task identity, or durable/runtime state ownership. Coding conventions and review guardrails remain in `AGENTS.md`.

Keep this reference current when adding, removing, renaming, or materially repurposing a package.

## Module Map

### Task System

| Module | Purpose |
|--------|---------|
| `my-task.el` | Stable public facade for task-visible commands, runtime-derived snapshots, discard-facing commands, compatibility aliases, and lazy subsystem loading. |
| `my-task-note.el` | Task note/front-matter IO, note-derived metadata, note lifecycle mutations, and persisted session metadata. |
| `my-task-session.el` | Worktree setup/resume, pickup/exit flows, live session lifecycle, bootstrap context, and selected-window restore. |
| `my-hephaestus.el` | Narrow adapter for deployed `hephaestus`: allocate/resume/release entry points plus private process and parsing helpers. |
| `my-task-index.el` | Transient in-memory claims and active-session state for the current Emacs session. |
| `my-worktree-repair.el` | Detached-worktree safety/recovery and narrow live task/worktree lookup wrappers. |
| `my-task-finish.el` | Finish/discard closeout and reusable-worktree teardown. |
| `my-task-list.el` | Dired task-list UI, filtering, and overlays. |

### Agent Backends

| Module | Purpose |
|--------|---------|
| `my-agent.el` | Backend-neutral launch, bootstrap-prompt dispatch, buffer naming, and backend dispatch. |
| `my-agent-pi.el` | Pi startup options, bootstrap wording, session-path registration/migration, and launch adapter. |

### Supporting Packages

| Module | Purpose |
|--------|---------|
| `my-git.el` | Shared git primitives. |
| `my-repo.el` | Live repo discovery from the `~/work/` layout. |
| `my-worktree.el` | Live git-worktree discovery, inspection, detach, and reclaim helpers. |

```text
my-task-list.el ───► my-task.el ──► my-task-note.el + lazy-loads my-task-session.el, my-worktree-repair.el, my-task-finish.el
my-task-session.el ─► my-task-note.el, my-agent.el, my-hephaestus.el, my-task-index.el, my-worktree-repair.el, my-worktree.el
my-hephaestus.el ───► my-worktree.el
my-worktree-repair.el ──► my-task-note.el, my-task-index.el, my-worktree.el
my-agent.el ────────► my-agent-pi.el
```

Agent-neutral lifecycle, review semantics, and durable state ownership belong in task-system packages, shared skills, or broader guidance. Backend adapters stay adapter-shaped and must not become generic workflow policy owners.

## Task Lifecycle Contract

Treat this as the target design when implementation temporarily differs and call out known mismatches.

### Canonical continuity versus runtime state

- Canonical task continuity lives in the task note plus task branch.
- The task note owns durable task facts, operator-facing audit history, and agent-neutral resumable metadata.
- The task branch owns durable work in progress. Preserve paused work there rather than in stash-like side channels.
- The task index is a transient claim/cache for the current Emacs session, never canonical resumability state.
- Live buffers and backend process state are optional continuation aids, not task identity.
- Derive finish/discard closeout from note, branch, and indexed worktree/session state rather than creating another deferred-lifecycle store.

### Command semantics

- **`pickup`** enters or re-enters a task. Restore continuity from note and branch first, then layer backend resume on durable session metadata.
- **Backend resume** is optional continuation help. Do not document silent fallback for stale metadata unless implementation guarantees it.
- **`exit`** pauses rather than closes. Leave the task `todo`, clear the live session, release the linked worktree, and keep the task resumable.
- **Dirty `exit`** checkpoints to the task branch rather than stashing. Do not assume pickup unwraps a WIP commit unless a later design explicitly guarantees safe semantics.
- **`finish`** is the user's declaration that work is complete under active merge, deploy, and verification rules.
- **Cleanup** follows finish/discard and owns branch teardown, destructive reset/clean/detach, index/session cleanup, note transition, and related closeout bookkeeping. It belongs in `my-task-finish.el`, not paused-work behavior.

### Ownership boundaries

- `my-task-note.el` owns note/front-matter IO, note-derived metadata, status mutations, and durable note-stored session metadata.
- `my-task-session.el` owns pickup/exit orchestration, live lifecycle, and the bridge between durable continuity and transient backend state.
- `my-hephaestus.el` owns the standalone CLI boundary, including launch, parsing, normalization, and error formatting.
- `my-task-index.el` owns transient claims and active-session flags.
- `my-worktree-repair.el` owns detached-worktree recovery and narrow live lookup wrappers.
- `my-task-finish.el` owns direct finish/discard mechanics and reusable-worktree teardown.
- Backend adapters own backend startup/resume mechanics and prompt wording only, accepting task-system metadata rather than inventing lifecycle policy.

## Placement Guide

- Task note CRUD, front matter, status, or note session metadata → `my-task-note.el`
- Stable task entry points, discard-facing commands, compatibility aliases, or runtime snapshots → `my-task.el`
- Worktree setup/resume, pickup/exit, live lifecycle, bootstrap context, or window restore → `my-task-session.el`
- Hephaestus CLI process/parsing/release semantics → `my-hephaestus.el`
- Transient task claims or active-session accessors → `my-task-index.el`
- Detached-worktree recovery or narrow live lookup → `my-worktree-repair.el`
- Task-list UI, filters, or overlays → `my-task-list.el`
- Finish/discard cleanup or reusable-worktree teardown → `my-task-finish.el`
- Backend-neutral selection, dispatch, or bootstrap routing → `my-agent.el`
- Pi-specific flags, bootstrap wording, CLI/env wiring, or session launch → `my-agent-pi.el`
- Repo/worktree discovery or low-level git → `my-repo.el`, `my-worktree.el`, or `my-git.el`

Create a package when a feature has a distinct state owner, async/persistence/backend boundary, an existing module has unrelated responsibilities, or multiple callers need a stable lazy-loaded API. When extracting:

1. Choose one owner for each durable fact or responsibility.
2. Keep `my-task.el` or `my-agent.el` as a facade only when outside callers need it.
3. Keep agent-neutral semantics out of backend adapters.
4. Use runtime `require` and `declare-function` across boundaries.
5. Update this map and placement guide in the same change.

Before adding a helper, variable, hook, customization, or module, ask whether obsolete code can be deleted, an existing owner can absorb the behavior, or a real second caller/async/ownership boundary justifies the abstraction.

## Task Identity

Prefer Denote task IDs over paths. IDs survive status/title renames; paths do not.

### Public boundary

1. `my/task-resolve-id` normalizes nil, a task ID, or a file path to an ID.
2. `my/task-file` resolves an ID to its current path at the point of use.
3. `my/task--resolve-id` and `my/task--get-file` are private to `my-task.el` and must not be called cross-module.

Public task functions accept flexible input and normalize immediately:

```elisp
;;;###autoload
(defun my/task-example (&optional task)
  "Do something with TASK.
TASK may be nil (context), task-id string, or file path."
  (interactive)
  (let* ((task-id (my/task-resolve-id task))
         (file (and task-id (my/task-file task-id))))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (unless file
      (user-error "Task file not found for: %s" task-id))
    ...))
```

- Pass IDs between functions.
- Re-resolve the path inside async callbacks.
- Do not store paths in closures, cache them across status transitions, or pass them internally when an ID is sufficient.
