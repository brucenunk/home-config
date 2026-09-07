{ inputs, ... }:

{
  perSystem =
    { pkgs, ... }:
    {
      checks.herdr-sync-workspaces-tests =
        pkgs.runCommand "herdr-sync-workspaces-tests"
          {
            nativeBuildInputs = [ pkgs.shellcheck ];
          }
          ''
            shellcheck \
              ${../../config/herdr/herdr-sync-workspaces.sh} \
              ${../../config/herdr/herdr-sync-workspaces.test.sh}
            ${pkgs.bash}/bin/bash ${../../config/herdr/herdr-sync-workspaces.test.sh} \
              ${../../config/herdr/herdr-sync-workspaces.sh} \
              ${pkgs.jq}/bin/jq \
              ${pkgs.bash}/bin/bash \
              ${pkgs.git}/bin/git \
              ${pkgs.coreutils}/bin \
              ${pkgs.flock}/bin/flock \
              ${pkgs.socat}/bin/socat
            touch "$out"
          '';
    };

  flake.modules.homeManager.herdr =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      cfg = config.brucenunk.homeManager.herdr;

      configReference = builtins.fromJSON (
        builtins.readFile "${inputs.herdr}/docs/next/website/src/data/config-reference.json"
      );
      configKeys = lib.concatMap (section: map (entry: entry.key) section.keys) configReference.sections;
      requiredConfigKeys = [
        "terminal.kitty_graphics"
        "theme.custom.dark.text"
        "theme.custom.light.text"
        "ui.sidebar.agents.rows"
        "ui.sidebar.spaces.rows"
        "ui.sidebar_max_width"
        "ui.sidebar_min_width"
        "ui.sidebar_width"
      ];
      missingConfigKeys = lib.subtractLists configKeys requiredConfigKeys;

      theme =
        name: (builtins.fromTOML (builtins.readFile ../../config/herdr/themes/${name}.toml)).theme.custom;

      herdrSyncWorkspaces = pkgs.writeShellApplication {
        name = "herdr-sync-workspaces";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.flock
          pkgs.git
          pkgs.jq
          pkgs.socat
          inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default
        ];
        text = builtins.readFile ../../config/herdr/herdr-sync-workspaces.sh;
      };

      settings = {
        onboarding = false;

        terminal = {
          kitty_graphics = true;
          new_cwd = "follow";
        };

        theme = {
          auto_switch = true;
          dark_name = "terminal";
          light_name = "terminal";
          name = "terminal";

          custom = {
            dark = theme "doric-obsidian";
            light = theme "doric-marble";
          };
        };

        ui = {
          sidebar_max_width = 48;
          sidebar_min_width = 30;
          sidebar_width = 32;
          status_indicators = "symbols";
          window_title = "{hostname}: {workspace}";

          sidebar = {
            agents.rows = [
              [
                "workspace"
                "tab"
              ]
              [
                "agent"
                "state_text"
              ]
            ];

            spaces.rows = [
              [ "workspace" ]
              [
                "branch"
                "git_status"
              ]
            ];
          };

          toast = {
            delay_seconds = 1;
            delivery = cfg.ui.toast.delivery;
          };
        };

        session.resume_agents_on_restore = true;
        remote.manage_ssh_config = false;

        update = {
          manifest_check = true;
          version_check = false;
        };
      };
    in
    {
      options.brucenunk.homeManager.herdr.ui.toast.delivery = lib.mkOption {
        type = lib.types.enum [
          "herdr"
          "terminal"
          "system"
          "off"
        ];
        default = "herdr";
        description = "Herdr notification delivery mechanism.";
      };

      config = {
        assertions = [
          {
            assertion = missingConfigKeys == [ ];
            message = "Pinned Herdr does not support required config keys: ${lib.concatStringsSep ", " missingConfigKeys}";
          }
        ];

        home.packages = [
          herdrSyncWorkspaces
        ]
        ++ lib.optional (
          pkgs.stdenv.hostPlatform.isLinux && cfg.ui.toast.delivery == "system"
        ) pkgs.libnotify;

        home.file.".pi/agent/extensions/herdr-agent-state.ts".source =
          "${inputs.herdr}/src/integration/assets/pi/herdr-agent-state.ts";

        programs.herdr = {
          enable = true;
          package = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default;
          inherit settings;
        };
      };
    };
}
