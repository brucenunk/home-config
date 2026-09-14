{ inputs, ... }:

let
  homeManagerModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      cfg = config.brucenunk.homeManager.herdr;

      configReference = builtins.fromJSON (
        builtins.readFile "${pkgs.herdr.src}/docs/next/website/src/data/config-reference.json"
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

        home.packages = lib.optional (
          pkgs.stdenv.hostPlatform.isLinux && cfg.ui.toast.delivery == "system"
        ) pkgs.libnotify;

        home.file.".pi/agent/extensions/herdr-agent-state.ts".source =
          "${pkgs.herdr.src}/src/integration/assets/pi/herdr-agent-state.ts";

        programs.herdr = {
          enable = true;
          package = pkgs.herdr;
          inherit settings;
        };
      };
    };
in
{
  perSystem =
    { pkgs, ... }:
    let
      home = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          homeManagerModule
          {
            home = {
              username = "herdr-module-check";
              homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then
                  "/Users/herdr-module-check"
                else
                  "/home/herdr-module-check";
              stateVersion = "25.05";
            };

            brucenunk.homeManager.herdr.ui.toast.delivery = "terminal";
          }
        ];
      };
      herdrConfig = home.config.xdg.configFile."herdr/config.toml".source;
    in
    {
      checks = {
        herdr-home-manager-module =
          assert home.config.home.file ? ".pi/agent/extensions/herdr-agent-state.ts";
          pkgs.runCommand "herdr-home-manager-module" { } ''
            ${pkgs.python3}/bin/python - ${herdrConfig} <<'PY'
            import sys
            import tomllib

            with open(sys.argv[1], "rb") as config_file:
                config = tomllib.load(config_file)

            assert config["terminal"]["kitty_graphics"] is True
            assert config["terminal"]["new_cwd"] == "follow"
            assert config["theme"]["custom"]["dark"]["text"] == "#e7e7e7"
            assert config["theme"]["custom"]["light"]["text"] == "#202020"
            assert config["remote"]["manage_ssh_config"] is False
            assert config["ui"]["sidebar_width"] == 32
            assert config["ui"]["sidebar_min_width"] == 30
            assert config["ui"]["sidebar_max_width"] == 48
            assert config["ui"]["sidebar"]["agents"]["rows"] == [
                ["workspace", "tab"],
                ["agent", "state_text"],
            ]
            assert config["ui"]["sidebar"]["spaces"]["rows"] == [
                ["workspace"],
                ["branch", "git_status"],
            ]
            assert config["ui"]["toast"]["delivery"] == "terminal"
            assert config["update"]["version_check"] is False
            PY
            touch "$out"
          '';

      };
    };

  flake.modules.homeManager.herdr = homeManagerModule;
}
