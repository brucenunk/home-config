{ inputs, mkPkgs, ... }:

let
  packageFor =
    pkgs:
    pkgs.buildGoModule {
      pname = "herdsman";
      version = "0.1.0";
      src = ../../go/herdsman;
      vendorHash = "sha256-lq+G1UfBMiAbnD9jNWN1Tn67KYXk770N5cQI7jUqHWU=";
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postInstall = ''
        wrapProgram "$out/bin/herdsman" \
          --suffix PATH : ${
            pkgs.lib.makeBinPath [
              pkgs.llm-agents.herdr
              pkgs.openssh
            ]
          }
      '';
      meta.mainProgram = "herdsman";
    };

  homeManagerModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.brucenunk.homeManager.herdsman.config;
      format = pkgs.formats.toml { };
      managedConfig = format.generate "herdsman-config.toml" {
        agent_names = cfg.agentNames;
        tasks_dir = cfg.tasksDir;
        default_base = cfg.defaultBase;
        default_gitdir = cfg.defaultGitdir;
        theme = cfg.theme;
        machines = lib.mapAttrs (_: repositories: { inherit repositories; }) cfg.machines;
        repositories = cfg.repositories;
      };
      themeEntries = lib.mapAttrs' (name: _: {
        name = "herdsman/themes/${name}";
        value.source = ../../config/herdsman/themes/${name};
      }) (lib.filterAttrs (_: type: type == "regular") (builtins.readDir ../../config/herdsman/themes));
    in
    {
      options.brucenunk.homeManager.herdsman.config = lib.mkOption {
        description = "Nix-managed Herdsman inventory, source directories, base refs and theme selection.";
        default = { };
        type = lib.types.submodule {
          options = {
            agentNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Agent name pool. Names must be unique and match Herdr's [a-z][a-z0-9_-]{0,31} rule.";
            };
            defaultBase = lib.mkOption {
              type = lib.types.str;
              default = "origin/main";
              description = "Default Git branch/ref, used as written without fetching.";
            };
            defaultGitdir = lib.mkOption {
              type = lib.types.str;
              default = "main";
              description = "Default source directory under ~/work/owner/repo; an ordinary checkout or bare repository, not a literal .git directory.";
            };
            machines = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
              default = { };
              description = "Repository slugs by Herdr saved-machine label; local is reserved.";
            };
            repositories = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    base = lib.mkOption {
                      type = lib.types.str;
                      default = cfg.defaultBase;
                      description = "Git branch/ref for new worktrees; independent of the source directory.";
                    };
                    gitdir = lib.mkOption {
                      type = lib.types.str;
                      default = cfg.defaultGitdir;
                      description = "Single source directory name under ~/work/owner/repo.";
                    };
                  };
                }
              );
              default = { };
              description = "Per-repository source directory and Git base ref overrides.";
            };
            tasksDir = lib.mkOption {
              type = lib.types.str;
              default = "~/work/tasks";
              description = "Local directory used by the task picker.";
            };
            theme = lib.mkOption {
              default = { };
              description = "Nix-managed theme selection.";
              type = lib.types.submodule {
                options = {
                  dark = lib.mkOption {
                    type = lib.types.str;
                    default = "doric-obsidian";
                    description = "Palette name used for dark terminals; absent files use terminal-native styling.";
                  };
                  light = lib.mkOption {
                    type = lib.types.str;
                    default = "doric-marble";
                    description = "Palette name used for light terminals; absent files use terminal-native styling.";
                  };
                  mode = lib.mkOption {
                    type = lib.types.enum [
                      "auto"
                      "light"
                      "dark"
                    ];
                    default = "auto";
                    description = "Detect the terminal background at startup, or force light/dark.";
                  };
                };
              };
            };
          };
        };
      };

      config = {
        home.packages = [ (packageFor pkgs) ];
        xdg.configFile = themeEntries // {
          "herdsman/config.toml".source = managedConfig;
        };
      };
    };
in
{
  flake.modules.homeManager.herdsman = homeManagerModule;

  perSystem =
    { system, ... }:
    let
      pkgs = mkPkgs system;
      package = packageFor pkgs;
      home = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          homeManagerModule
          {
            home = {
              username = "herdsman-module-check";
              homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then
                  "/Users/herdsman-module-check"
                else
                  "/home/herdsman-module-check";
              stateVersion = "25.05";
            };
            brucenunk.homeManager.herdsman.config = {
              agentNames = [ "example-agent" ];
              machines.local = [
                "example/repo"
                "example/bare"
                "example/train"
              ];
              repositories = {
                "example/bare" = {
                  base = "origin/master";
                  gitdir = "master.git";
                };
                "example/train".base = "refs/heads/train/first-pr";
              };
            };
          }
        ];
      };
      configFile = home.config.xdg.configFile."herdsman/config.toml";
    in
    {
      packages.herdsman = package;
      checks.herdsman = package;
      checks.herdsman-home-manager-module = builtins.deepSeq home.activationPackage.drvPath (
        assert !configFile.force;
        assert !(home.config.home.activation ? herdsmanInitialConfig);
        pkgs.runCommand "herdsman-home-manager-module" { } ''
          ${pkgs.python3}/bin/python - ${configFile.source} <<'PY'
          import sys
          import tomllib
          with open(sys.argv[1], "rb") as f:
              config = tomllib.load(f)
          assert config["default_base"] == "origin/main"
          assert config["default_gitdir"] == "main"
          assert config["agent_names"] == ["example-agent"]
          assert config["theme"] == {
              "mode": "auto", "light": "doric-marble", "dark": "doric-obsidian"
          }
          assert config["machines"]["local"]["repositories"] == [
              "example/repo", "example/bare", "example/train"
          ]
          assert config["repositories"]["example/bare"] == {
              "base": "origin/master", "gitdir": "master.git"
          }
          assert config["repositories"]["example/train"] == {
              "base": "refs/heads/train/first-pr", "gitdir": "main"
          }
          PY
          ${pkgs.python3}/bin/python - \
            ${home.config.xdg.configFile."herdsman/themes/doric-marble.toml".source} \
            ${home.config.xdg.configFile."herdsman/themes/doric-obsidian.toml".source} <<'PY'
          import sys
          import tomllib
          for path, text in zip(sys.argv[1:], ["#202020", "#e7e7e7"]):
              with open(path, "rb") as f:
                  palette = tomllib.load(f)
              assert set(palette) == {"colors"}
              assert palette["colors"]["text"] == text
              assert set(palette["colors"]) == {
                  "text", "muted", "accent", "selection_background",
                  "selection_text", "filename_secondary", "filename_muted",
                  "match", "error",
              }
          PY
          ${package}/bin/herdsman --help | grep -F 'herdsman start'
          touch "$out"
        ''
      );
    };
}
