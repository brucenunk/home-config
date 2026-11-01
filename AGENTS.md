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

## Checks and tests

Add checks only for a concrete failure mode: broken behaviour, unsafe mutation,
consumer overrides or integration boundaries. Prefer exercising real generated
output over inspecting configuration attributes.

Do not add tests that merely repeat configuration constants, maintain file or
export inventories, enforce cosmetic structure, or assert that removed features
remain absent. Do not duplicate coverage already provided by package builds,
existing suites or general module evaluation. Extend an existing suite where
practical; a new feature does not automatically need a new flake check.

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
