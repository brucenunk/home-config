# Home Manager Flake

## Changes

- Read `docs/dendritic-modules.md` before adding, moving, or splitting a feature.
- Keep implementation and registration together in
  `flake-modules/features/<capability>.nix`.
- Recursive discovery registers modules; hosts and downstream consumers must
  opt into each module explicitly.
- Keep host identity and machine composition in `hosts/`.
- Prefer native Home Manager options and typed custom options for real module
  interfaces.

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

## Verification

After changing this repository:

1. Stage all intended files; flakes do not include untracked or unstaged files
   when a staged tree is used for remote verification.
2. Run `./scripts/check-home-configuration . 'james@wampa'` on an x86_64 Linux
   host to build Wampa without activating it.
3. When deployment to Wampa is explicitly intended, read
   `docs/activation.md` and follow the row matching the source machine and
   target. Do not infer or substitute another activation route.

Build success is not activation or runtime-pickup evidence.
