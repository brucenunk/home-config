# Dendritic module architecture

`flake.nix` recursively discovers flake-parts modules under `flake-modules/`.
Discovery registers modules; it does not activate the Home Manager features they
publish.

Registration modules publish named capabilities under
`flake.modules.homeManager.<name>`. A host or downstream consumer activates a
feature by explicitly adding that module to its Home Manager `imports` list.
Keep feature names descriptive and independent of a particular host.

## Feature-first topology

Put ordinary capabilities in `flake-modules/features/<capability>.nix`, with
implementation and registration co-located. A registration file that only
forwards to an implementation elsewhere is not the intended architecture. Keep
separate files for configuration assets, packages, top-level hosts, or
substantial reusable libraries when those files have a clear owner.

Personal policy and reusable mechanics belong with the capability they
configure rather than in broad `personal`, `generic`, transport, or profile
directories. Downstream private modules may import or configure public modules,
but public modules must not refer back to private policy.

## Module interfaces

Prefer native typed Home Manager options. A reusable feature may provide policy
defaults with `lib.mkDefault`, allowing a host or downstream module to override
them through normal module merging. Add a custom option only when no suitable
native option exists and more than one owner must communicate through that
boundary.

Top-level `hosts/` is the composition root for configurations owned by this
flake. Host files list selected features explicitly and own machine identity,
state versions, local package overrides, and endpoint values. Do not hide
composition behind broad profiles or make recursive discovery activate a
feature.

A feature file may register more than one module when they are coherent
adapters for the same capability. Configuration assets stay outside
`flake-modules/` when they are data consumed by a feature. Package expressions
and substantial source trees may remain under their own clearly owned paths.

## Custom option namespace

Custom options that form a public cross-owner interface belong under:

```nix
brucenunk.homeManager.<capability>
```

Prefer native Home Manager options whenever they already express the boundary.
Do not add repository-owned options to upstream namespaces such as `programs`
or `services`. Keep each custom declaration and its implementation in the
capability feature file that exports the corresponding Home Manager module.

Within a capability option set, keep the conventional `enable` and `package`
attributes first, followed by a blank line and the remaining attributes in
lexical order. Apply the same order to declarations, defaults, and examples.

These options are introduced by an exported module; they are not independent
flake outputs. An in-flake host imports through `config.flake`:

```nix
imports = [ config.flake.modules.homeManager.ghostty ];
```

An external consumer imports the same interface through its input:

```nix
{
  imports = [ inputs.home-config.modules.homeManager.ghostty ];

  brucenunk.homeManager.ghostty = {
    package = pkgs.ghostty;

    canonicalLinuxService.enable = false;
    extraConfig = ''
      font-size = 12
    '';
  };
}
```

The module continues to own and deploy the shared base configuration and theme
assets. The consumer owns only its fragment, package compatibility choice, and
any replacement service or session integration.

`scripts/check-exported-home-manager-modules` compares the evaluated option set
with plain Home Manager and rejects public custom options outside the prefixed
namespace.

## Current composition boundaries

- `ghostty` deploys the shared config and complete theme set. Consumers may
  select `brucenunk.homeManager.ghostty.package`, append `extraConfig`, and
  control `canonicalLinuxService.enable`. A consumer that disables the
  canonical service owns its replacement service and session environment.
- `pi` exposes its deployment interface under
  `brucenunk.homeManager.pi`. Its public theme and extension directories are
  defaults, so provider or transport adapters can replace them without
  `mkForce`.
- `git-maintenance` accepts consumer repository paths through
  `brucenunk.homeManager.gitMaintenance.repositories`.
- `doric-waybar-themes` deploys only the complete generated Waybar theme set.
  Consumers with a different bar layout or launcher can import it without the
  `waybar` module's Wampa policy. The full `waybar` module imports these assets
  itself.
- `agents` already separates shared file deployment from Darwin-only packages
  through platform compatibility checks; it needs no additional interface.
- `darkman` intentionally retains the ordinary-login Niri integration. A
  nested or otherwise specialised session owns its service lifecycle, portal
  policy, environment recovery, and live-reload mechanics rather than
  parameterising the public implementation with private host behavior.
