# my-lisp Coding Conventions

## Required Architecture Context

Before changing task packages, module boundaries, or task identity, read
`ARCHITECTURE.md`. Update it when adding, removing, renaming, or materially
repurposing a package or ownership boundary.

## Checklist

Before modifying or creating my-lisp files:

- [ ] Task code manages files and filtering only; no git, repository selection,
  agent sessions, worktrees, status transitions, or dependency orchestration.
- [ ] Function names follow `my/<noun>-<verb>`; predicates end in `-p`.
- [ ] New internals use `my/<module>--...`; cross-module callers use public APIs.
- [ ] Public and interactive functions have `;;;###autoload`.
- [ ] Commentary lists every public function/command.
- [ ] The file ends with `(provide 'my-MODULE)` and its standard footer.
- [ ] New code removes stale helpers, branches, and state rather than preserving them.
- [ ] New abstractions have a real second use or a genuine ownership boundary.

Compare `grep -c ';;;###autoload' my-MODULE.el` with Commentary entries when public
APIs change. Preserve native Denote identity and ordinary Dired operations.

## Review Guardrails

Review changed modules and their direct callers/consumers for:

- **UI-thread stalls:** do not add synchronous broad scans, repair, or recomputation
  to interactive/read paths. Use bounded reads and explicit freshness work.
- **Mixed responsibilities:** keep capture, file configuration, and list display
  in their existing narrow owners.
- **Split state ownership:** avoid duplicate sources of truth; prefer native file
  and Denote state over custom indexes or caches.
- **Internal API leakage:** do not call another module's `my/<module>--*` helper.
- **Timer/hook refresh by default:** prefer explicit notifications or targeted
  buffer-local hooks. Use timers only when events are genuinely unavailable.
- **Unsafe background persistence:** never overwrite unrelated or unsaved content.
- **Complexity without payoff:** remove dead paths and single-use indirection.

## Naming and Visibility

Use noun-verb names matching the module or feature:

```elisp
my/task-add
my/task-file-p
my/task-list-filter-sort
```

Internals use a double dash after the module prefix, for example
`my/task-list--filter-save`. Internals are not interactive, not autoloaded, and
not called outside their owning module.

## File Structure

```elisp
;;; my-MODULE.el --- Brief description -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Brief purpose.
;; Public commands/functions/predicates:
;;   - my/foo-bar — what it does

;;; Code:

(require 'cl-lib)

;;;###autoload
(defun my/foo-bar ()
  "Do the documented thing."
  (interactive)
  ...)

(provide 'my-MODULE)
;;; my-MODULE.el ends here
```

## Core Lisp and Cleanup

- Use `cl-defun` for keyword arguments and `pcase-let` for structured destructuring.
- Use `cl-return-from` for named early returns.
- Remove unused `require` and stale `declare-function` forms.
- Use `define-error` only when callers need a domain hierarchy; use `user-error`
  for direct user-facing failures.
- Remove dead internals, redundant compatibility branches, unused dependencies,
  and wrappers that no longer clarify ownership. Do not preserve fallbacks
  without a supported caller or data source.
