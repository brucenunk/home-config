# Home Manager Flake

## Changes

Before adding, moving or splitting a feature, read `docs/dendritic-modules.md`
for module ownership, registration and host composition rules.

## Emacs configuration

Before changing Emacs configuration, Lisp implementations or Emacs-related Nix
integration, read `docs/emacs-literate.md` for source ownership, package
configuration conventions and safe verification.

## Agent guidance

Before changing instruction routing or context composition, read
`config/agents/GUIDANCE-VERIFICATION.md` for static checks and deployed routing
probes.

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
