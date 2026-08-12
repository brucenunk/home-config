# my-lisp Coding Conventions

## Required Architecture Context

Before changing task-system packages, agent backends, module boundaries, task identity, or durable/runtime state ownership, read `ARCHITECTURE.md` in this directory. It owns the module map, lifecycle contract, placement guide, and stable task-identity rules. Update it when a change adds, removes, renames, or materially repurposes a package or ownership boundary.

## Agent Checklist

Before modifying or creating my-lisp files:

- [ ] Git operations use `my/git-*` primitives, never raw process/shell calls to git.
- [ ] Async git passes an explicit directory to `my/git-run-async`.
- [ ] Function names follow `my/<noun>-<verb>`; predicates end in `-p`.
- [ ] New internals use `my/<module>--...`; cross-module callers use public APIs.
- [ ] Public and interactive functions have `;;;###autoload`.
- [ ] Commentary lists every public function/command.
- [ ] The file ends with `(provide 'my-MODULE)` and its standard footer.
- [ ] New code removes stale helpers, branches, and state rather than preserving them by default.
- [ ] New abstractions have a real second use, async boundary, or ownership boundary.

Compare `grep -c ';;;###autoload' my-MODULE.el` with Commentary entries when public APIs change.

## Review Guardrails

Review the changed module and direct callers/consumers for:

- **UI-thread stalls:** interactive, modeline, and task-list read paths must not add synchronous scans, git calls, broad recomputation, or repair. Prefer bounded indexed reads and async, idle, or explicit freshness work.
- **Mixed responsibilities:** do not make one module own unrelated metadata, UI, repair, and lifecycle concerns. Put behavior in the narrowest existing owner or a focused module.
- **Split state ownership:** do not create another source of truth without a clear owner and update path. Repair/reconciliation logic is a prompt to ask whether state can be derived or centralized.
- **Split live/index semantics:** do not serve fresh blocking state to one caller and stale indexed state to another for the same fact. Prefer consistent indexed behavior and one refresh path.
- **Internal API leakage:** never call another module's `my/<module>--*` helper; expose a narrow public API from the owner.
- **Timer/hook refresh by default:** prefer explicit event-driven notifications or targeted buffer-local hooks. Use timers only when events are genuinely unavailable.
- **Unsafe background persistence:** background refresh/repair must be restart-friendly, concurrency-safe, scoped to owned state, and unable to overwrite unrelated durable state.
- **Complexity without payoff:** remove dead paths and fold single-use indirection back into callers when that clarifies ownership.

## Git and Directory Handling

All git operations must use `my-git.el` primitives.

| Layer | Required pattern |
|-------|------------------|
| Primitive helpers such as `my/git-run`, `my/git-lines`, `my/git-success-p` | Ambient `default-directory` is idiomatic. |
| Repo/worktree APIs accepting `DIR` | Use the corresponding `*-in-dir` helper. |
| Interactive commands computing one path for a short synchronous sequence | May bind `default-directory` locally. |
| Any async operation | Pass `DIR` explicitly to `my/git-run-async`; never rely on ambient directory in callbacks. |

Available primitives include `my/git-run`, `my/git-run-or-error`, `my/git-success-p`, and `my/git-lines`, plus their `*-in-dir` variants. Network operations use `my/git-run-async`.

```elisp
;; BAD
(call-process "git" nil t nil "status")
(shell-command-to-string "git branch")

;; GOOD: API accepts DIR, so use an explicit-directory primitive.
(defun my/example-check (dir)
  "Check something in DIR."
  (my/git-lines-in-dir dir "status" "--porcelain"))

;; GOOD: async always passes DIR.
(my/git-run-async
 worktree-path
 '("fetch" "origin")
 :name "fetch"
 :on-success (lambda (output _code) ...)
 :on-error (lambda (code output) ...))
```

## Naming and Visibility

Use noun-verb names matching the module/feature:

```elisp
my/task-pickup
my/worktree-clean-p
my/repo-merge-local
my/git-run-async
```

- Boolean functions end in `-p`.
- Public APIs use `my/<module>-<noun>-<verb>` as appropriate.
- Internals use a double dash after the module prefix, for example `my/task-list--filter-save`.
- Internal functions are not autoloaded, not interactive, and not called outside their module.

## File Structure

```elisp
;;; my-MODULE.el --- Brief description -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Brief purpose.
;;
;; Commands:
;;   - my/foo-bar — what it does
;; Functions:
;;   - my/foo-baz — what it does
;; Predicates:
;;   - my/foo-p — what it checks

;;; Code:

(require 'cl-lib)

;;; Section heading

...

(provide 'my-MODULE)
;;; my-MODULE.el ends here
```

Use Sync/Async Commentary groups for async-heavy modules when clearer.

## Async APIs

Higher-level async functions use keyword callbacks:

```elisp
(cl-defun my/task-example-async (path &key on-success on-error)
  "Do something with PATH.
ON-SUCCESS receives the result. ON-ERROR receives an error message."
  ...)
```

- Higher-level `:on-success` receives result value(s).
- Higher-level `:on-error` receives one formatted error string.
- `my/git-run-async` is the lower-level exception: its error callback receives `(EXIT-CODE OUTPUT)`. Adapt that to one message before invoking higher-level error callbacks.

Use `my/task-session-setup-worktree-async` in `my-task-session.el` as the canonical nested-operation example for explicit directories and error propagation.

## Additional Patterns

### Autoloads

Add `;;;###autoload` to interactive commands, externally used functions, and cross-package entry points. Do not autoload internals.

### Core Lisp

- Use `cl-defun` for keyword arguments.
- Use `pcase-let` for structured destructuring.
- Use `cl-return-from` for named early returns.
- Remove unused `require` and stale `declare-function` forms.

### Cleanup

When touching a file, remove dead internals, redundant compatibility branches, unused dependencies, and single-use wrappers or aliases that no longer clarify ownership. Do not preserve a fallback without a supported caller or data source.

### Errors

Use `define-error` for domain errors that need a hierarchy:

```elisp
(define-error 'my/task-error "Task error")
(define-error 'my/task-done-error "Task already complete" 'my/task-error)
```

Use `user-error` for direct user-facing failures that need no programmatic hierarchy.
