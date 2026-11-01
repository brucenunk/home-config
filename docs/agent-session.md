# Emacs agent sessions

Each command starts a new Pi conversation:

| Command | Use |
| --- | --- |
| `M-x my/agent-session-start-new-worktree` | Choose a repository, machine and base ref; create a sibling worktree and compose a brief. |
| `M-x my/agent-session-start-from-file` | Select a saved Denote Org task under `~/work/docs/tasks/`; create a worktree and submit its full contents. |
| `M-x my/agent-session-start-in-directory` | Choose a machine and directory; start there without creating a worktree. |

These require the [machine catalogue](agent-catalogue.md), agent-shell/ACP
packages and `pi-acp` on the selected machine. A sole eligible machine is
selected automatically; otherwise selection is explicit. Always confirm the
base ref for new worktrees. To build on another branch, choose it there.
Local branches resolve without fetching; a configured remote prefix such as
`origin/train/part-one` fetches that branch. Tags and revision expressions are
not accepted. Use `refs/heads/origin/example` to disambiguate a local branch
whose name begins with a remote name.

Task authoring is described in `work/TASKS.md`. Unsaved task edits block launch;
Markdown files are not accepted. Optional `model` and `thinking` hints override
Pi independently; absent hints leave Pi defaults intact. Unsupported overrides
stop automatic submission. A task's original path may be inaccessible on the
agent host: the launcher sends the saved contents, not a remote file reference.
Native `@file` processing still applies to that text.

## Launch failures

Failures report the retained directory, branch and shell buffer when available.
Nothing is automatically removed or resent. An interrupted Git operation may
have partially applied: inspect the reported path before creating another
worktree. After resolving the cause, open the retained directory and start
agent-shell normally. If submission may have reached the agent, inspect the
conversation before sending again.

Launching does not authorize agents to create worktrees or control other
sessions. Task completion does not trigger cleanup.

## Screenshots and clipboard images

Capture on the **machine running Emacs**, then attach in viewport compose:

| Host | Capture to clipboard | Attach without sending |
| --- | --- | --- |
| macOS | `Ctrl+Cmd+Shift+4`, select a region | `C-c C-y` |
| Wampa (Niri/Wayland) | `Print`, select and confirm | `C-c C-y` |

Graphical Emacs needs `pngpaste` on macOS or `wl-paste` on Wayland. On macOS,
`C-c C-s` also captures directly; Escape cancels. If capture is denied, check
Screen Recording permission for the application hosting Emacs in System
Settings, and restart that application if requested.

Attachments append to the draft; send explicitly with `C-c C-c`. Captures live
under `~/work/agent-shell/screenshots/` on the Emacs host, including for remote
sessions. Avoid same-kind captures within one second: upstream filenames can
collide and overwrite an earlier attachment. Files are not automatically pruned.
Remote image delivery requires an adapter advertising image support; a plain
path mention is not equivalent to an image attachment.

## Insert file references from search

From an editable composer:

1. Use `M-s d` (`consult-fd`) for a file or `M-s g` (`consult-ripgrep`) for a line.
2. Highlight a candidate and press `C-. @` (`my/agent-shell-insert-reference`).
   Leave Embark's exit-on-action enabled so Consult restores the composer.

This inserts without submitting: `@src/example.go` or
`@src/example.go (line 42)`. The line is a hint; context is the **whole file**.
Paths with spaces use native quoting. Paths become relative to the originating
agent's working directory; ordinary undo removes the insertion.

Remote searches/directories, filenames containing quotes or newlines, and
multi-candidate insertion are unsupported. Embark's native transformation can
also reject filenames with unset environment-variable names, such as `$slug`.

For completion while typing, use an explicit directory prefix (`./`, `../`,
`~/` or `/usr/`). `C-c p f` also completes filenames, including bare root paths;
a prefix argument prompts for the base directory.

## Attention and idle cleanup

Finished turns and permission requests produce a local chime, not a popup.
Active interaction delays or acknowledges it; a finished turn does not mean the
task is complete. `M-x my/agent-notification-visit-waiting` selects a waiting
session. Set `my/agent-notification-sound-file` to nil to mute.

Idle sessions are **closed without confirmation after four days**, including
time while Emacs is closed. Busy sessions, permission waits, unsent drafts and
pinned sessions are protected; merely leaving a session visible is not enough.
Worktree and branch deletion are disabled. External transcripts and agent-saved
sessions are not explicitly deleted, but resumability depends on the agent.
Native temporary sessions can remove their marked temporary directory; the
three launch commands above do not mark worktrees as temporary.

- `M-x agent-shell-gc-toggle-keep`: pin/unpin; pins do not survive Emacs restarts.
- `M-x agent-shell-gc-list`: inspect idle times and protection reasons.
- `M-x agent-shell-gc-now`: sweep now, still applying TTLs and protections.
- `M-x agent-shell-gc-mode`: disable/re-enable collection.

Transcripts are stored directly under `~/work/agent-shell/transcripts/` on the
Emacs host, even for remote agents. Old transcript locations are not migrated.
Do not shorten global TTLs or collect real sessions merely to test cleanup.

For deployment use [activation.md](activation.md). Never load feature-worktree
Lisp into the shared Emacs daemon; live checks must use approved deployed files.
