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
