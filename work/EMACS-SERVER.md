<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Emacs Server Guidance

Read this document for Emacs debugging, live evaluation, state inspection, UI work, or recovery from a wedged `emacsclient`. Follow any narrower repository guidance as well.

## Live Inspection

An Emacs server normally runs continuously. Prefer `emacsclient -e '(elisp-expression)'` for debugging, evaluation, and state inspection.

Loading or evaluating feature-worktree Lisp in an existing session requires explicit user authorization for the change and target session. Keep the test within that scope and agree how to undo its effects or restart if needed; reloading Lisp does not necessarily remove earlier state. This is session-only testing, not persistent deployment: it does not require Home Manager activation and does not authorize changing deployed files. Actual deployment must still follow the repository's activation procedure, with runtime pickup verified separately.

Use `screencapture` on macOS or `niri msg action screenshot` in a Niri session when exact Emacs layout or styling state matters.

## Wedged Clients

If `emacsclient -e` stops returning, stop issuing further clients. A healthy GUI does not prove that the background daemon is healthy. Inspect first:

```bash
ps -Ao pid,ppid,etime,command | rg 'Emacs|emacsclient'
```

If blocked clients are accumulating behind a long-lived daemon, kill only the stuck evaluation clients and that daemon—not unrelated GUI Emacs processes—then restart and verify once:

```bash
pkill -f '^emacsclient .*-e '
pkill -f '^[^ ]*Emacs --daemon$'
emacs --daemon
emacsclient -e '(version)'
```

Recheck the process list, then resume task commands one at a time so another wedge is immediately visible.
