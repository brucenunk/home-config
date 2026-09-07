{ inputs, ... }:

{
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
              [
                "workspace"
                "state_text"
              ]
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

        home.packages = lib.optional (
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
