# Home Manager verification boundaries

Home Manager verification is split by the contract being tested. Run the
platform-neutral checks on both supported systems; a successful check on one
system is not evidence for the other.

## Exported-module contract

```sh
./scripts/check-exported-home-manager-modules
```

The script evaluates each module supported by the invoking platform with the
repository's shared `llm-agents` package overlay, no consumer-specific overlays,
and no `extraSpecialArgs`. Exported modules may rely on that shared package set;
external consumers must provide the same overlay. The script checks that:

- the complete public export name set remains stable;
- every native-platform module can produce an activation derivation in
  isolation; and
- options added by exported modules use the
  `brucenunk.homeManager.<capability>` namespace.

`darkman`, `niri`, and `waybar` are Linux-only and are deliberately omitted
from the Darwin evaluation. All other exports are evaluated on both Linux and
Darwin. The script only evaluates derivation paths; it does not realize a
foreign-platform derivation.

The former `check-exported-pi-module` command was redundant: Pi's exported-module
isolation is covered here, while its option behavior is covered by the Pi flake
check.

## Feature-owned checks

Feature behavior is checked by flake checks declared beside the module that
owns it:

| Check | Platforms | Regression caught |
| --- | --- | --- |
| `ghostty-home-manager-module` | Linux, Darwin | Package overrides remain effective, extra configuration remains appended, the two generated themes remain deployed, and disabling the canonical Linux service suppresses its link. |
| `herdr-home-manager-module` | Linux, Darwin | The generated Herdr TOML remains parseable and retains terminal, Doric theme, sidebar, notification, SSH, and update policy, and the matching Pi integration remains deployed. The native check realizes only the generated configuration needed to inspect that artifact. |
| `pi-home-manager-module` | Linux, Darwin | Consumers can disable Pi and override its extension and theme directory defaults with `null`. |
| `doric-waybar-themes-home-manager-module` | Linux, Darwin | The portable Waybar theme module continues to deploy its theme directory recursively. |
| `git-maintenance-home-manager-module` | Darwin | A non-empty repository list enables Git maintenance settings and the launchd schedule. |
| `emacs-home-manager-module` | Linux | The module defaults to `pkgs.emacs`, while ordinary consumer assignments can select `emacs31` or `emacs-nox`; this guards the `mkDefault` priority contract. |

Run all checks for the invoking platform with:

```sh
nix flake check
```

The Pi implementation tests are also flake checks and run under the same
command.

## Personal-host boundary

```sh
./scripts/check-home-configuration . 'james@wampa'
```

Run this command on x86_64 Linux. It evaluates Wampa's identity and builds the
personal activation package without activating it. This is composition and
build evidence for `james@wampa`, not a reusable-module contract check,
deployment evidence, or runtime-pickup evidence.

The old broad exported-module script explicitly asserted that Wampa selected
`emacs-pgtk`. That assertion was removed: the host owns the direct package
selection, and building Wampa already verifies that the selected package can
participate in its activation package. A deliberate host policy change should
not require editing a reusable-module contract test.

## Coverage disposition

The previous broad script's assertions were assigned as follows:

- isolated activation derivations and custom-option namespace checks remain in
  the exported-module contract script;
- the three Linux-only export-presence assertions are superseded by checking
  the complete public export name set and by the explicit Darwin exclusion
  list;
- historical negative checks for `programs.gitMaintenance` and
  `programs.piAgent` are subsumed by the general custom-option namespace check;
- Emacs package-priority behavior moved to the Emacs feature check;
- Ghostty configuration, themes, package override, and service control moved
  to the Ghostty feature check;
- Git maintenance option behavior moved to its Darwin feature check;
- Herdr generated settings and Pi integration moved to the Herdr feature
  check;
- nullable Pi directory overrides moved to the Pi feature check;
- portable Waybar theme deployment moved to the Waybar feature check; and
- the personal Wampa Emacs package equality assertion was intentionally
  removed in favor of the personal-host build boundary described above.
