# brucenunk/home-config

James's Home Manager configuration and reusable feature modules.

The flake exports `homeConfigurations."james@wampa"` and modules under
`flake.modules.homeManager`. Consumers opt into each module explicitly and must
provide the shared `llm-agents` package overlay.

## Checks

On x86_64 Linux, build Wampa without activating it:

```sh
./scripts/check-home-configuration . 'james@wampa'
```

Check exported interfaces and feature behaviour on each supported native platform:

```sh
./scripts/check-exported-home-manager-modules
nix flake check
```

Stage intended files before verification so new sources are included.
Deployment requires explicit authorization: follow [the activation
procedure](docs/activation.md). Build success does not prove activation or
pickup by running Emacs/Pi processes.

## Maintenance

- `flake-modules/features/`: feature implementation and registration; see
  [module conventions](docs/dendritic-modules.md).
- `hosts/`: machine composition.
- `config/`: managed assets; see [Emacs maintenance](docs/emacs-literate.md),
  [agent sessions](docs/agent-session.md) and [Pi assets](config/pi/README.md).
- `pkgs/`, `rust/`, `swift/`: package definitions and source.
