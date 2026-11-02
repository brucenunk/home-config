# Maintaining Emacs configuration

Edit `config/emacs/my-emacs.org` for settings, bindings, hooks, file associations
and integration calls. Nix tangles it into `early-init.el`, `init.el` and
`my-emacs-modules/`; generated files are not editable sources.

Handwritten implementations live in `config/emacs/my-lisp/`, with ERT suites in
`config/emacs/tests/`. Package and grammar installation belongs to
`flake-modules/features/emacs.nix`, not runtime Emacs package installation.

Document only non-obvious operations, safety constraints and important rationale
not already clear in code. Prefer rationale beside the relevant code. Do not add
helper inventories, change narratives, test-coverage lists, verification results
or speculative documentation TODOs. Delete obsolete prose rather than preserving
a migration history. A code change alone does not require a documentation change.

## Emacs Lisp configuration

- Keep one `use-package` declaration per package across repository-maintained
  configuration. Inspect existing declarations before adding configuration.
- Extend the owning declaration's `:init`, `:config`, `:hook`, or `:bind` rather
  than adding scattered deferred blocks or duplicate declarations.
- Put mode-specific configuration, including file and interpreter associations,
  in that mode's declaration (`:mode` / `:interpreter`), not a generic `emacs`
  declaration or unrelated module. Add a single declaration for the mode if
  needed. Consolidation must preserve ownership, not just remove duplicates.
- Keep feature-specific implementation functions in their owning module; call a
  registration function from the package declaration when appropriate.
- Preserve lazy loading, bindings, and behavior whether dependencies load before
  or after the configuration module. Add focused load-order tests when changing
  deferred registration.
- Deferred forms remain appropriate for genuine cross-package integration,
  reload-sensitive behavior, and reusable libraries. Explain retained exceptions
  beside the code; do not add `use-package` dependencies to reusable libraries
  merely for consistency.

## Generate locally

```sh
output=$(mktemp -d)
./scripts/tangle-emacs-config "$output"
```

Use a fresh disposable output directory, never the source or deployed directory.
Inspect `init.el` and `my-emacs-modules/` there. Source blocks for each destination
are concatenated in document order; keep complete Lisp forms and each package
declaration together. Write Org prose as single-line paragraphs for soft wrapping.

## Verify

Stage intended files so Nix includes new sources, then build `.#emacs-config`
and affected `.#checks.<system>.<name>` checks, or run `nix flake check` for all
native-platform checks. Run the required Wampa build from the repository README.
For manual ERT, use the configured Emacs package with the generated module
directory, `my-lisp/` and `tests/` on `load-path`.

Prefer isolated batch Emacs for automated tests. With explicit user authorization
for the change and target session, feature-worktree Lisp may be loaded or evaluated
in an existing shared Emacs process for session-only testing, without Home Manager
activation. Before live access, read `~/work/EMACS-SERVER.md` for safe server
access. Keep evaluation within the authorized scope and agree how to undo the
session changes or restart if needed; reloading Lisp need not undo hooks, advice,
timers or other state from an earlier version.

Session-only testing does not authorize persistent deployment or changes to
deployed files. Deployment still requires explicit authorization and the matching
route in [activation.md](activation.md). Report isolated checks, session-only
runtime testing and deployment separately; neither a build nor activation proves
the running Emacs process loaded the change.
