# brucenunk/home-config

James's Home Manager configuration and reusable feature modules.

The flake exports `homeConfigurations."james@wampa"` and modules under
`flake.modules.homeManager`. Consumers opt into each module explicitly and must
provide the shared `llm-agents` package overlay.

## Maintenance

- `flake-modules/features/`: feature implementation and registration.
- `hosts/`: machine composition.
- `config/`: managed assets.
- `pkgs/`: package definitions and source.
