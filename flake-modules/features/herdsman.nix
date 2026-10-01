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
      package = packageFor pkgs;
      herdrPackage = pkgs.llm-agents.herdr;
      format = pkgs.formats.toml { };
      popupRunner = pkgs.writeShellScript "herdsman-popup" ''
        if ${package}/bin/herdsman start; then
          exit 0
        else
          status=$?
          printf '\nHerdsman exited with status %s. Inspect the error above before retrying.\nPress Enter to close.\n' "$status"
          read -r acknowledgement || true
          exit "$status"
        fi
      '';
      pluginManifest = format.generate "herdr-plugin.toml" {
        id = "brucenunk.herdsman";
        name = "Herdsman";
        version = "0.1.0";
        min_herdr_version = "0.9.1";
        platforms = [
          "linux"
          "macos"
        ];
        actions = [
          {
            id = "start";
            title = "Start task";
            command = [ "./herdsman-plugin" ];
          }
        ];
        panes = [
          {
            id = "launcher";
            title = "Start task";
            placement = "popup";
            width = "80%";
            height = "80%";
            command = [ popupRunner ];
          }
        ];
      };
      pluginStarter = pkgs.writeShellScript "herdsman-plugin" ''
        exec "''${HERDR_BIN_PATH:-${herdrPackage}/bin/herdr}" plugin pane open \
          --plugin brucenunk.herdsman --entrypoint launcher
      '';
      # Herdr canonicalizes the manifest and derives plugin_root from its parent.
      # A symlinked manifest would incorrectly make /nix/store the plugin root.
      plugin = pkgs.runCommand "herdsman-plugin" { } ''
        mkdir -p "$out"
        cp ${pluginManifest} "$out/herdr-plugin.toml"
        cp ${pluginStarter} "$out/herdsman-plugin"
      '';
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
        home.packages = [ package ];
        # Keep the registry user-owned; Herdr merges this link with other plugins.
        home.activation.herdsmanPlugin = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
          # Register offline with the pinned CLI, independent of any older server.
          # This socket cannot exist in the immutable generated plugin directory.
          run ${pkgs.coreutils}/bin/env \
            XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome} \
            XDG_DATA_HOME=${lib.escapeShellArg config.xdg.dataHome} \
            HERDR_SOCKET_PATH=${plugin}/offline.sock \
            ${herdrPackage}/bin/herdr plugin link \
            ${lib.escapeShellArg "${config.xdg.configHome}/herdsman/plugin"}
        '';
        programs.herdr.settings = lib.mkIf config.programs.herdr.enable {
          keys.command = [
            {
              key = "prefix+t";
              type = "plugin_action";
              command = "brucenunk.herdsman.start";
              description = "Start task";
            }
          ];
        };
        xdg.configFile = themeEntries // {
          "herdsman/config.toml".source = managedConfig;
          "herdsman/plugin".source = plugin;
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
            programs.herdr.enable = true;
            programs.herdr.package = pkgs.llm-agents.herdr;
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
        assert home.config.home.activation ? herdsmanPlugin;
        assert
          home.config.programs.herdr.settings.keys.command == [
            {
              key = "prefix+t";
              type = "plugin_action";
              command = "brucenunk.herdsman.start";
              description = "Start task";
            }
          ];
        pkgs.runCommand "herdsman-home-manager-module" { } ''
          plugin=${home.config.xdg.configFile."herdsman/plugin".source}
          ${pkgs.python3}/bin/python - "$plugin/herdr-plugin.toml" <<'PY'
          import sys
          import tomllib
          with open(sys.argv[1], "rb") as f:
              plugin = tomllib.load(f)
          assert plugin["id"] == "brucenunk.herdsman"
          assert plugin["min_herdr_version"] == "0.9.1"
          assert plugin["platforms"] == ["linux", "macos"]
          assert plugin["actions"] == [{
              "id": "start", "title": "Start task", "command": ["./herdsman-plugin"]
          }]
          pane_command = plugin["panes"][0]["command"]
          assert len(pane_command) == 1
          assert plugin["panes"] == [{
              "id": "launcher", "title": "Start task", "placement": "popup",
              "width": "80%", "height": "80%", "command": pane_command
          }]
          # Exercise the runner with only its Herdsman executable mocked.
          import os
          import subprocess
          import tempfile
          with open(pane_command[0]) as f:
              runner = f.read()
          assert "${package}/bin/herdsman start" in runner
          with tempfile.TemporaryDirectory() as directory:
              mock = os.path.join(directory, "herdsman")
              with open(mock, "w") as f:
                  f.write('#!${pkgs.runtimeShell}\necho "launch diagnostic"\nexit "$MOCK_STATUS"\n')
              os.chmod(mock, 0o755)
              script = runner.replace("${package}/bin/herdsman", mock)
              env = dict(os.environ, MOCK_STATUS="0")
              success = subprocess.run(["${pkgs.runtimeShell}", "-c", script],
                  input="", text=True, capture_output=True, env=env, timeout=5)
              assert success.returncode == 0
              assert "Press Enter" not in success.stdout
              env["MOCK_STATUS"] = "7"
              failure = subprocess.Popen(["${pkgs.runtimeShell}", "-c", script],
                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                  text=True, env=env)
              lines = []
              while True:
                  line = failure.stdout.readline()
                  assert line, "runner exited before acknowledging failure"
                  lines.append(line)
                  if "Press Enter" in line:
                      break
              assert failure.poll() is None
              assert "launch diagnostic" in "".join(lines)
              failure.communicate(input="\n", timeout=5)
              assert failure.returncode == 7
          assert not any(k in plugin for k in ["startup", "events", "build"])
          PY
          # No real server or user registry: validate link/relink offline in a sandbox.
          export HOME="$PWD/home"
          export XDG_CONFIG_HOME="$HOME/.config"
          export XDG_DATA_HOME="$HOME/.local/share"
          export XDG_RUNTIME_DIR="$PWD/runtime"
          export HERDR_SOCKET_PATH="$plugin/offline.sock"
          mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
          # Explicit directories/socket must override a stale activation environment.
          XDG_CONFIG_HOME="$PWD/stale-config" XDG_DATA_HOME="$PWD/stale-data" \
            HERDR_SOCKET_PATH="$PWD/stale.sock" ${pkgs.coreutils}/bin/env \
            XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
            HERDR_SOCKET_PATH="$plugin/offline.sock" \
            ${pkgs.llm-agents.herdr}/bin/herdr plugin link "$plugin"
          test ! -e "$PWD/stale-config/herdr/plugins.json"
          ${pkgs.llm-agents.herdr}/bin/herdr plugin link "$plugin"
          ${pkgs.python3}/bin/python - "$XDG_CONFIG_HOME/herdr/plugins.json" <<'PY'
          import json
          import sys
          with open(sys.argv[1]) as f:
              plugins = json.load(f)
          assert len(plugins) == 1
          assert plugins[0]["plugin_id"] == "brucenunk.herdsman"
          assert plugins[0]["enabled"] is True
          PY
          cat >mock-herdr <<'SH'
          #!${pkgs.runtimeShell}
          printf '%s\n' "$@"
          SH
          chmod +x mock-herdr
          HERDR_BIN_PATH="$PWD/mock-herdr" ${pkgs.python3}/bin/python - \
            "$XDG_CONFIG_HOME/herdr/plugins.json" "$plugin" >shim-args <<'PY'
          import json
          import os
          import subprocess
          import sys
          with open(sys.argv[1]) as f:
              plugin = json.load(f)[0]
          assert plugin["plugin_root"] == os.path.realpath(sys.argv[2])
          subprocess.run(plugin["actions"][0]["command"], cwd=plugin["plugin_root"], check=True)
          PY
          printf '%s\n' plugin pane open --plugin brucenunk.herdsman --entrypoint launcher >expected-args
          cmp shim-args expected-args
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
