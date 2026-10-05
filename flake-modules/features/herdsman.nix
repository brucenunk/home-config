{
  config,
  inputs,
  mkPkgs,
  ...
}:

let
  gitData = config.flake.lib.git;
  piData = config.flake.lib.pi;

  packageFor =
    pkgs:
    let
      piNode = pkgs.llm-agents.pi.override { useBun = false; };
    in
    pkgs.buildGoModule {
      pname = "herdsman";
      version = "0.1.0";
      src = ../../go/herdsman;
      vendorHash = "sha256-lq+G1UfBMiAbnD9jNWN1Tn67KYXk770N5cQI7jUqHWU=";
      nativeBuildInputs = [ pkgs.makeWrapper ];
      preCheck = ''
        export HERDSMAN_MODEL_ARGUMENT_FIXTURE="$TMPDIR/herdsman-model-arguments.json"
      '';
      postCheck = ''
        ${pkgs.nodejs}/bin/node --input-type=module - "$HERDSMAN_MODEL_ARGUMENT_FIXTURE" <<'JS'
        import assert from "node:assert/strict";
        import { readFileSync } from "node:fs";
        import { resolveCliModel } from "${piNode}/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/model-resolver.js";
        const fixtures = JSON.parse(readFileSync(process.argv[2], "utf8"));
        const models = fixtures.map(({ Reference }) => {
          const slash = Reference.indexOf("/");
          return { provider: Reference.slice(0, slash), id: Reference.slice(slash + 1) };
        });
        const modelRuntime = { getModels: () => models, hasConfiguredAuth: () => true };
        for (const { Reference, Args, Rejected } of fixtures) {
          const piArgs = Args.slice(Args.indexOf("--") + 1);
          const argument = flag => {
            const index = piArgs.indexOf(flag);
            assert(index >= 0, `missing ''${flag}`);
            return piArgs[index + 1];
          };
          const result = resolveCliModel({
            cliProvider: argument("--provider"), cliModel: argument("--model"),
            cliThinking: argument("--thinking"), modelRuntime,
          });
          assert.equal(result.error, undefined);
          assert.equal(result.warning, undefined);
          const selected = `''${result.model.provider}/''${result.model.id}`;
          if (Rejected) {
            assert.notEqual(selected, Reference);
          } else {
            assert.equal(selected, Reference);
          }
          assert.equal(result.thinkingLevel, undefined);
        }
        // Case-only IDs are not exact choices to Pi. The Go catalogue tests
        // reject this inventory before launch; reproduce why using emitted args.
        const ambiguousModels = [...models, { provider: "example", id: "Foo" }];
        const { Args } = fixtures.find(fixture => fixture.Reference === "example/foo");
        const ambiguous = resolveCliModel({
          cliProvider: Args[Args.indexOf("--provider") + 1],
          cliModel: Args[Args.indexOf("--model") + 1],
          cliThinking: "high",
          modelRuntime: { getModels: () => ambiguousModels, hasConfiguredAuth: () => true },
        });
        assert.notEqual(`''${ambiguous.model.provider}/''${ambiguous.model.id}`, "example/foo");
        JS
      '';
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
      options,
      pkgs,
      ...
    }:
    let
      cfg = config.brucenunk.homeManager.herdsman.config;
      machineName = config.brucenunk.homeManager.herdsman.machineName;
      machines = config.brucenunk.homeManager.herdsman.machines;
      localMachine = if machineName == null then null else machines.${machineName} or null;
      piSettingsDefaults =
        if options.brucenunk.homeManager ? pi then
          config.brucenunk.homeManager.pi.settingsDefaults
        else
          null;
      piDefaults =
        if piSettingsDefaults == null then
          { }
        else
          builtins.fromJSON (builtins.readFile piSettingsDefaults);
      localDefaultModel =
        if
          builtins.isAttrs piDefaults
          && builtins.isString (piDefaults.defaultProvider or null)
          && builtins.isString (piDefaults.defaultModel or null)
          && piDefaults.defaultProvider != ""
          && piDefaults.defaultModel != ""
        then
          "${piDefaults.defaultProvider}/${piDefaults.defaultModel}"
        else
          null;
      catalogue = {
        localMachine = machineName;
        machines = lib.mapAttrs (
          _: machine:
          let
            models = map (
              model:
              model
              // {
                defaultThinking =
                  if builtins.elem "medium" model.thinkingLevels then
                    "medium"
                  else if builtins.elem "off" model.thinkingLevels then
                    "off"
                  else
                    "";
              }
            ) (piData.projectModels machine.models);
          in
          {
            repositories = builtins.attrNames machine.repositories;
            defaultBaseRefs = lib.mapAttrs (
              _: repository: "origin/${repository.defaultBranch}"
            ) machine.repositories;
            defaultModel =
              if machine.defaultModel != null then
                machine.defaultModel
              else if models != [ ] then
                (builtins.head models).name
              else
                "";
            inherit models;
          }
        ) machines;
      };
      package = packageFor pkgs;
      herdrPackage = pkgs.llm-agents.herdr;
      format = pkgs.formats.toml { };
      popupRunner = pkgs.writeShellScript "herdsman-popup" ''
        if ${package}/bin/herdsman; then
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
            title = "Herdsman";
            command = [ "./herdsman-plugin" ];
          }
        ];
        panes = [
          {
            id = "launcher";
            title = "Herdsman";
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
        local_machine_name = if machineName == null then "" else machineName;
        agent_names = cfg.agentNames;
        tasks_dir = cfg.tasksDir;
        daemon = {
          refresh_interval = cfg.daemon.refreshInterval;
          queue_capacity = cfg.daemon.queueCapacity;
          refresh_concurrency = cfg.daemon.refreshConcurrency;
        };
        theme = cfg.theme;
        machines = lib.mapAttrs' (name: machine: {
          name = if name == machineName then "local" else name;
          value = {
            repositories = lib.mapAttrs (_: repository: {
              path = repository.path;
              default_branch = repository.defaultBranch;
            }) machine.repositories;
          }
          // lib.optionalAttrs (machine.defaultModel != null) {
            default_model = machine.defaultModel;
          };
        }) machines;
      };
      themeEntries = lib.mapAttrs' (name: _: {
        name = "herdsman/themes/${name}";
        value.source = ../../config/herdsman/themes/${name};
      }) (lib.filterAttrs (_: type: type == "regular") (builtins.readDir ../../config/herdsman/themes));
      daemonCommand = [
        "${package}/bin/herdsman"
        "daemon"
        "--config"
        "${config.xdg.configHome}/herdsman/config.toml"
      ];
      daemonRunner = pkgs.writeShellScript "herdsman-daemon" ''
        # Expand Home Manager's shell-valued session paths/variables, just as
        # interactive sessions do. Service-manager Environment does not expand.
        unset __HM_SESS_VARS_SOURCED
        . ${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh
        exec ${lib.escapeShellArgs daemonCommand}
      '';
      daemonEnvironment = {
        HOME = config.home.homeDirectory;
        XDG_CONFIG_HOME = config.xdg.configHome;
        XDG_CACHE_HOME = config.xdg.cacheHome;
        XDG_DATA_HOME = config.xdg.dataHome;
        # Service managers do not run an interactive shell. Include managed
        # tools and consumer session paths (for SSH ProxyCommand helpers).
        PATH = lib.concatStringsSep ":" ([
          "${config.home.profileDirectory}/bin"
          "/run/current-system/sw/bin"
          "/usr/local/bin"
          "/usr/bin"
          "/bin"
        ]);
      };
    in
    {
      options.brucenunk.homeManager.herdsman.machineName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "This host's machine name; the current launcher renders it as local in TOML only.";
      };
      options.brucenunk.homeManager.herdsman.machines = lib.mkOption {
        default = { };
        description = "Git/Pi definitions keyed by machine name, shared with Emacs task metadata.";
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }: {
              options = {
                defaultModel = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = if name == machineName then localDefaultModel else null;
                  description = "Initial provider/model selection without a task hint. The local machine inherits Pi's Nix settings defaults; null falls back to the first catalogue model.";
                };
                repositories = gitData.repositoryOptions.repositories;
                models = piData.modelsOption;
              };
            }
          )
        );
      };
      options.brucenunk.homeManager.herdsman.config = lib.mkOption {
        description = "Nix-managed Herdsman operational settings; repositories and models come from machines.";
        default = { };
        type = lib.types.submodule {
          options = {
            agentNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Agent name pool. Names must be unique and match Herdr's [a-z][a-z0-9_-]{0,31} rule.";
            };
            daemon = lib.mkOption {
              default = { };
              description = "Daemon refresh and in-memory queue policy; restart the service after changes.";
              type = lib.types.submodule {
                options = {
                  queueCapacity = lib.mkOption {
                    type = lib.types.ints.between 1 1024;
                    default = 32;
                    description = "Maximum pending requests, excluding the executing request.";
                  };
                  refreshConcurrency = lib.mkOption {
                    type = lib.types.ints.between 1 64;
                    default = 4;
                    description = "Maximum simultaneous snapshot refreshes; mutations remain serial.";
                  };
                  refreshInterval = lib.mkOption {
                    type = lib.types.str;
                    default = "30s";
                    description = "Positive Go duration such as 30s, 1m, or 500ms; validated by Herdsman.";
                  };
                };
              };
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
        assertions = [
          {
            assertion =
              machines == { } || (machineName != null && machines ? ${machineName} && !(machines ? local));
            message = "Set Herdsman's own machineName when supplying machines; local is reserved for the launcher TOML.";
          }
          {
            assertion =
              localMachine == null
              || !(options.brucenunk.homeManager ? git)
              || config.brucenunk.homeManager.git.repositories == localMachine.repositories;
            message = "Herdsman and Git must share this machine's repository definition.";
          }
          {
            assertion =
              localMachine == null
              || !(options.brucenunk.homeManager ? pi)
              || config.brucenunk.homeManager.pi.models == localMachine.models;
            message = "Herdsman and Pi must share this machine's model configuration.";
          }
        ]
        ++ lib.mapAttrsToList (name: machine: {
          assertion =
            machine.defaultModel == null
            || builtins.elem machine.defaultModel (
              map (model: model.name) (piData.projectModels machine.models)
            );
          message = "Herdsman defaultModel for ${name} must be a model in that machine's catalogue.";
        }) machines;
        home.packages = [ package ];
        systemd.user.services.herdsman = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          Unit.Description = "Herdsman cached discovery and execution daemon";
          Service = {
            ExecStart = "${daemonRunner}";
            Environment = lib.mapAttrsToList (name: value: "${name}=${value}") daemonEnvironment;
            Restart = "on-failure";
            RestartSec = 5;
            TimeoutStopSec = 10;
            UMask = "0077";
          };
          Install.WantedBy = [ "default.target" ];
        };
        launchd.agents.herdsman = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
          enable = true;
          config = {
            Label = "org.brucenunk.herdsman";
            ProgramArguments = [ "${daemonRunner}" ];
            EnvironmentVariables = daemonEnvironment;
            RunAtLoad = true;
            KeepAlive = true;
            ThrottleInterval = 5;
            ProcessType = "Background";
            StandardOutPath = "${config.home.homeDirectory}/Library/Logs/herdsman.log";
            StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/herdsman.log";
          };
        };
        home.activation.herdsmanLogDirectory = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
          lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
            run mkdir -p ${lib.escapeShellArg "${config.home.homeDirectory}/Library/Logs"}
          ''
        );
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
              description = "Herdsman";
            }
          ];
        };
        xdg.configFile = themeEntries // {
          "herdsman/catalogue.json".source = pkgs.writeText "herdsman-catalogue.json" (
            builtins.toJSON catalogue
          );
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
      homeDirectory =
        if pkgs.stdenv.hostPlatform.isDarwin then
          "/Users/herdsman-module-check"
        else
          "/home/herdsman-module-check";
      home = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          homeManagerModule
          {
            home = {
              username = "herdsman-module-check";
              inherit homeDirectory;
              stateVersion = "25.05";
            };
            programs.herdr.enable = true;
            programs.herdr.package = pkgs.llm-agents.herdr;
            brucenunk.homeManager.herdsman = {
              machineName = "machine-a";
              machines = {
                "machine-a" = {
                  repositories = {
                    "example/repo".path = "${homeDirectory}/work/example/repo/main";
                    "example/bare" = {
                      path = "/srv/git/example.git";
                      defaultBranch = "master";
                    };
                    "example/custom" = {
                      path = "${homeDirectory}/work/example/custom/main";
                      defaultBranch = "release/stable";
                    };
                  };
                  models.providers.example = {
                    api = "openai-responses";
                    baseUrl = "https://private-endpoint.invalid";
                    apiKey = "!private-credential-command";
                    models = [
                      {
                        id = "vendor/model";
                        reasoning = true;
                        thinkingLevelMap.minimal = null;
                      }
                    ];
                  };
                };
                "machine-b".repositories."example/repo" = {
                  path = "/srv/git/remote/repo.git";
                  defaultBranch = "master";
                };
              };
            };
            brucenunk.homeManager.herdsman.config.agentNames = [ "example-agent" ];
            home.sessionPath = [ "$HOME/.local/bin" ];
          }
        ];
      };
      configFile = home.config.xdg.configFile."herdsman/config.toml";
      piDefaultHome = home.extendModules {
        modules = [
          config.flake.modules.homeManager.pi
          {
            brucenunk.homeManager.pi = {
              enable = false;
              models = home.config.brucenunk.homeManager.herdsman.machines.machine-a.models;
              settingsDefaults = builtins.toFile "herdsman-pi-defaults.json" (
                builtins.toJSON {
                  defaultProvider = "example";
                  defaultModel = "vendor/model";
                }
              );
            };
          }
        ];
      };
      explicitDefaultHome = home.extendModules {
        modules = [
          { brucenunk.homeManager.herdsman.machines.machine-a.defaultModel = "example/vendor/model"; }
        ];
      };
      clearedDefaultHome = piDefaultHome.extendModules {
        modules = [ { brucenunk.homeManager.herdsman.machines.machine-a.defaultModel = null; } ];
      };
      partialDefaultHome = piDefaultHome.extendModules {
        modules = [
          {
            brucenunk.homeManager.pi.settingsDefaults = pkgs.lib.mkForce (
              builtins.toFile "herdsman-pi-partial-defaults.json" (
                builtins.toJSON { defaultProvider = "example"; }
              )
            );
          }
        ];
      };
      invalidDefaultHome = home.extendModules {
        modules = [
          { brucenunk.homeManager.herdsman.machines.machine-a.defaultModel = "example/unknown"; }
        ];
      };
      nonfirstDefaultHome = home.extendModules {
        modules = [
          {
            brucenunk.homeManager.herdsman.machines.machine-a = {
              defaultModel = "example/alternate";
              models = pkgs.lib.mkForce (
                let
                  original = home.config.brucenunk.homeManager.herdsman.machines.machine-a.models;
                in
                pkgs.lib.recursiveUpdate original {
                  providers.example.models = original.providers.example.models ++ [
                    {
                      id = "alternate";
                      reasoning = false;
                    }
                  ];
                }
              );
            };
          }
        ];
      };
    in
    {
      packages.herdsman = package;
      checks.herdsman = package;
      checks.herdsman-home-manager-module = builtins.deepSeq home.activationPackage.drvPath (
        assert !(builtins.tryEval invalidDefaultHome.activationPackage.drvPath).success;
        assert
          piDefaultHome.config.xdg.configFile."herdsman/catalogue.json".source
          == home.config.xdg.configFile."herdsman/catalogue.json".source;
        assert !configFile.force;
        assert !(home.config.home.activation ? herdsmanInitialConfig);
        assert home.config.home.activation ? herdsmanPlugin;
        assert
          if pkgs.stdenv.hostPlatform.isDarwin then
            builtins.length home.config.launchd.agents.herdsman.config.ProgramArguments == 1
            && home.config.launchd.agents.herdsman.config.KeepAlive
          else
            builtins.length home.config.systemd.user.services.herdsman.Service.ExecStart == 1;
        assert
          home.config.programs.herdr.settings.keys.command == [
            {
              key = "prefix+t";
              type = "plugin_action";
              command = "brucenunk.herdsman.start";
              description = "Herdsman";
            }
          ];
        pkgs.runCommand "herdsman-home-manager-module" { } ''
          daemonRunner=${
            if pkgs.stdenv.hostPlatform.isDarwin then
              builtins.head home.config.launchd.agents.herdsman.config.ProgramArguments
            else
              builtins.head home.config.systemd.user.services.herdsman.Service.ExecStart
          }
          ${pkgs.python3}/bin/python - "$daemonRunner" <<'PY'
          import os
          import subprocess
          import sys
          import tempfile
          with open(sys.argv[1]) as f:
              runner = f.read()
          assert 'exec ${package}/bin/herdsman daemon --config ' in runner
          with tempfile.TemporaryDirectory() as directory:
              mock = os.path.join(directory, "herdsman")
              with open(mock, "w") as f:
                  f.write('#!${pkgs.runtimeShell}\nprintf "%s\\n" "$PATH"\nprintf "%s\\n" "$@"\n')
              os.chmod(mock, 0o755)
              result = subprocess.run(["${pkgs.runtimeShell}", "-c",
                  runner.replace("${package}/bin/herdsman", mock)],
                  capture_output=True, text=True, check=True,
                  env=dict(os.environ, HOME=directory, PATH="/usr/bin:/bin"))
              lines = result.stdout.splitlines()
              assert directory + "/.local/bin" in lines[0].split(":")
              assert "$HOME" not in lines[0]
              assert lines[1:] == ["daemon", "--config", "${home.config.xdg.configHome}/herdsman/config.toml"]
          PY
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
              "id": "start", "title": "Herdsman", "command": ["./herdsman-plugin"]
          }]
          pane_command = plugin["panes"][0]["command"]
          assert len(pane_command) == 1
          assert plugin["panes"] == [{
              "id": "launcher", "title": "Herdsman", "placement": "popup",
              "width": "80%", "height": "80%", "command": pane_command
          }]
          # Exercise the runner with only its Herdsman executable mocked.
          import os
          import subprocess
          import tempfile
          with open(pane_command[0]) as f:
              runner = f.read()
          assert "if ${package}/bin/herdsman; then" in runner
          with tempfile.TemporaryDirectory() as directory:
              mock = os.path.join(directory, "herdsman")
              with open(mock, "w") as f:
                  f.write('#!${pkgs.runtimeShell}\n[ "$#" -eq 0 ] || exit 99\necho "workflow diagnostic"\nexit "$MOCK_STATUS"\n')
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
              assert "workflow diagnostic" in "".join(lines)
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
          ${pkgs.python3}/bin/python - ${configFile.source} ${
            home.config.xdg.configFile."herdsman/catalogue.json".source
          } ${piDefaultHome.config.xdg.configFile."herdsman/config.toml".source} ${
            explicitDefaultHome.config.xdg.configFile."herdsman/config.toml".source
          } ${clearedDefaultHome.config.xdg.configFile."herdsman/config.toml".source} ${
            partialDefaultHome.config.xdg.configFile."herdsman/config.toml".source
          } ${nonfirstDefaultHome.config.xdg.configFile."herdsman/catalogue.json".source} <<'PY'
          import json
          import sys
          import tomllib
          with open(sys.argv[1], "rb") as f:
              config = tomllib.load(f)
          assert "default_base" not in config and "default_gitdir" not in config
          assert config["agent_names"] == ["example-agent"]
          assert config["local_machine_name"] == "machine-a"
          assert all("default_model" not in machine for machine in config["machines"].values())
          for path in sys.argv[3:5]:
              with open(path, "rb") as f:
                  selected = tomllib.load(f)
              assert selected["machines"]["local"]["default_model"] == "example/vendor/model"
              assert "default_model" not in selected["machines"]["machine-b"]
          for path in sys.argv[5:7]:
              with open(path, "rb") as f:
                  cleared = tomllib.load(f)
              assert "default_model" not in cleared["machines"]["local"]
          assert config["daemon"] == {
              "refresh_interval": "30s", "queue_capacity": 32, "refresh_concurrency": 4,
          }
          assert config["theme"] == {
              "mode": "auto", "light": "doric-marble", "dark": "doric-obsidian"
          }
          assert set(config["machines"]["local"]["repositories"]) == {
              "example/bare", "example/repo", "example/custom"
          }
          assert config["machines"]["local"]["repositories"]["example/bare"] == {
              "path": "/srv/git/example.git", "default_branch": "master"
          }
          assert config["machines"]["machine-b"]["repositories"]["example/repo"] == {
              "path": "/srv/git/remote/repo.git", "default_branch": "master"
          }
          assert "repositories" not in config
          with open(sys.argv[2]) as f:
              text = f.read()
          catalogue = json.loads(text)
          assert set(catalogue) == {"localMachine", "machines"}
          assert catalogue["localMachine"] == "machine-a"
          assert set(catalogue["machines"]) == {"machine-a", "machine-b"}
          for name, destination in [("machine-a", "local"), ("machine-b", "machine-b")]:
              machine = catalogue["machines"][name]
              assert set(machine) == {"repositories", "defaultBaseRefs", "defaultModel", "models"}
              assert machine["repositories"] == sorted(config["machines"][destination]["repositories"])
              assert machine["defaultBaseRefs"] == {
                  slug: "origin/" + repository["default_branch"]
                  for slug, repository in config["machines"][destination]["repositories"].items()
              }
          assert catalogue["machines"]["machine-a"]["models"] == [{
              "name": "example/vendor/model", "thinkingLevels": ["off", "low", "medium", "high"],
              "defaultThinking": "medium"
          }]
          assert catalogue["machines"]["machine-a"]["defaultModel"] == "example/vendor/model"
          assert catalogue["machines"]["machine-b"]["defaultModel"] == ""
          assert catalogue["machines"]["machine-b"]["models"] == []
          with open(sys.argv[7]) as f:
              nonfirst = json.load(f)["machines"]["machine-a"]
          assert nonfirst["defaultModel"] == "example/alternate"
          assert nonfirst["models"][1] == {
              "name": "example/alternate", "thinkingLevels": ["off"], "defaultThinking": "off"
          }
          assert "private-" not in text and "/srv/git" not in text and "default_branch" not in text
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
          ${package}/bin/herdsman --help 2>&1 | grep -F 'herdsman daemon'
          touch "$out"
        ''
      );
    };
}
