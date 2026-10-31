# Literate Emacs configuration

Edit `config/emacs/my-emacs.org` for configuration: settings, bindings, hooks,
file associations and integration calls. Its outline is the overview of the
setup. Prose explains decisions and trade-offs; an unresolved reason gets an
Org comment such as `# TODO: Document why we chose this behaviour.`

## Ownership

- Org tangles `early-init.el`, `init.el` and capability-focused files under
  `my-emacs-modules/`. These are build outputs, not checked-in editable sources.
- `config/emacs/my-lisp/` contains handwritten function implementations and
  local libraries. Configuration calls into them; library code does not import
  the generated configuration. Genuine multi-package deferred registration stays
  in its owning integration library, with an explicit registration call in Org.
- `config/emacs/tests/` contains ERT suites, separate from deployed libraries
  and generated configuration.
- `flake-modules/features/emacs.nix` owns package/grammar installation and
  deployment. Each configured package has one owning `use-package` declaration.
  Do not install packages from Emacs at runtime.

Follow the existing public function names and lazy-loading contracts when moving
code. Keep behaviour changes separate from the structural migration. Link to
handwritten libraries rather than embedding substantial function bodies in Org.

## Declaration and prose conventions

- Keep a single `use-package` declaration for each package. Shared behaviour
  such as mixed-pitch activation belongs with the package being enabled;
  agent-only registrations belong in the Agents section.
- Put ordinary registrations together in `:hook`. Use bare hook names when
  enabling the package’s own inferred `PACKAGE-mode`, and explicit
  `(HOOK . FUNCTION)` pairs for other callbacks. Use `:custom` for user options.
  Keep mode activation, advice, list updates and upstream hook removal in
  `:config`. Use `:init` only when setup must precede package loading.
- Retain explicit `add-hook` calls for abnormal hook names such as
  `after-make-frame-functions`, required ordering, or registrations that must
  wait for the owning package to load. Explain the exception beside the code.
- Use `:bind` for command bindings and `:bind-keymap` for prefix maps. Keep
  package links beneath their owning heading, never above it.
- Describe custom helpers and integration hooks in the surrounding prose,
  including what they change and why their load timing matters.
- Write prose as single-line paragraphs for soft wrapping. Source blocks with
  the same tangle destination are concatenated in document order; split
  complete Lisp forms into separate blocks when that helps annotation, but
  keep each package declaration together.
- Subtree `header-args:emacs-lisp+` properties override only the destination,
  inheriting common arguments from the file header. Generated-file comments
  and lexical-binding headers belong inside Lisp blocks, not in prose.

## Generate and inspect locally

From the worktree root:

```sh
output=$(mktemp -d)
./scripts/tangle-emacs-config "$output"
# Inspect "$output/init.el" and "$output/my-emacs-modules/".
```

This uses batch Emacs with no user configuration. Output is deliberately explicit:
never tangle into the deployed configuration or the source directory. Use a fresh
output directory so removed modules cannot remain from an earlier render.

Nix runs the same tangler in `pkgs/emacs-config.nix` and deploys its output through
Home Manager. Org parsing and Babel are not involved in normal Emacs startup.
The editable Org source is also available as `~/.config/emacs/my-emacs.org`;
edit the worktree original, not that Nix-store-backed deployment.

## Verification

Stage intended files first so Nix includes new sources. On x86_64 Linux:

```sh
nix build --no-link .#emacs-config
nix build --no-link \
  .#checks.x86_64-linux.emacs-literate \
  .#checks.x86_64-linux.emacs-deferred \
  .#checks.x86_64-linux.emacs-mode-selection \
  .#checks.x86_64-linux.emacs-denote \
  .#checks.x86_64-linux.emacs-agent-shell \
  .#checks.x86_64-linux.emacs-excali \
  .#checks.x86_64-linux.emacs-tramp-rpc \
  .#checks.x86_64-linux.agent-catalogue-home-manager-module
./scripts/check-home-configuration . 'james@wampa'
```

Tests must use the generated module directory plus `my-lisp/` and `tests/` on
`load-path`. The literate check validates generated Lisp, declaration ownership,
and isolated startup; the other suites exercise the affected capabilities.
For a focused manual ERT invocation, use the package-complete Emacs environment
and substitute its generated module path for `GENERATED`:

```sh
emacs --batch -Q -L GENERATED/my-emacs-modules \
  -L "$PWD/config/emacs/my-lisp" -L "$PWD/config/emacs/tests" \
  -l my-emacs-deferred-tests -f ert-run-tests-batch-and-exit
```

A successful build is isolated worktree verification, not activation or evidence
that the shared Emacs daemon has loaded the change. Activation requires an
explicit deployment request and the matching route in `docs/activation.md`.
Never load feature-worktree Lisp into the shared daemon.
