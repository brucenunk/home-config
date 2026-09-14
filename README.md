# brucenunk/home-config

James's personal Home Manager configuration and reusable feature modules.

The flake exports the personal Linux configuration
`homeConfigurations."james@wampa"` and capability-oriented modules under
`flake.modules.homeManager`. Importing the flake registers modules but activates
none of them; consumers select each module explicitly.

## Check Wampa

```sh
./scripts/check-home-configuration . 'james@wampa'
```

The command evaluates the configuration identity and builds its activation
package without activating it. On each supported platform, verify separately
that exported modules have no hidden consumer requirements and run the
feature-owned checks:

```sh
./scripts/check-exported-home-manager-modules
nix flake check
```

The exported-module command uses plain nixpkgs without consumer overlays or
`extraSpecialArgs`; `nix flake check` covers behavior owned by individual
features. See [`docs/home-manager-checks.md`](docs/home-manager-checks.md) for
the assertion inventory and Linux, Darwin, and personal-host boundaries.

For deliberate deployment, follow the source-machine-to-target matrix in
[`docs/activation.md`](docs/activation.md). It identifies the exact source and
target, invokes the Wampa activation package directly, and keeps build,
activation, and long-lived runtime pickup as separate evidence.

## Transitional Pi state

The personal Wampa output installs Pi and its public themes and extensions, but
intentionally supplies no provider, model catalogue, endpoint, or settings
defaults. Pi is allowed to remain unconfigured and non-functional until a later
private/provider adapter is assigned to its final owning repository.

An existing mutable `~/.pi/agent/settings.json` is not removed or rewritten by
this output. It may temporarily retain a default provider that is no longer
defined. Pi commands and the deployed review helper may therefore fail until a
later provider adapter configures a valid provider and model catalogue.

## Layout

- `flake-modules/features/`: named Home Manager modules.
- `hosts/wampa.nix`: personal-only Wampa composition.
- `config/`: managed personal application and agent assets.
- `pkgs/`, `rust/`, `swift/`: package definitions and source.

See `docs/dendritic-modules.md` for the module architecture, custom option
namespace, and stable composition boundaries.
