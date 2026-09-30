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
      cfg = config.brucenunk.homeManager.herdsman.initialConfig;
      format = pkgs.formats.toml { };
      initialConfig = format.generate "herdsman-config.toml" {
        agent_names = cfg.agentNames;
        tasks_dir = cfg.tasksDir;
        default_base = cfg.defaultBase;
        machines = lib.mapAttrs (_: repositories: { inherit repositories; }) cfg.machines;
        repositories = lib.mapAttrs (_: base: { inherit base; }) cfg.repositoryBases;
      };
      configPath = "${config.xdg.configHome}/herdsman/config.toml";
    in
    {
      options.brucenunk.homeManager.herdsman.initialConfig = lib.mkOption {
        description = "Initial writable inventory. Activation seeds it only when absent; later edits are user-owned.";
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
              default = "main";
              description = "Default source checkout directory and base branch.";
            };
            machines = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
              default = { };
              description = "Repository slugs by Herdr saved-machine label; local is reserved.";
            };
            repositoryBases = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Per-repository base overrides.";
            };
            tasksDir = lib.mkOption {
              type = lib.types.str;
              default = "~/work/tasks";
              description = "Local directory used by the task picker.";
            };
          };
        };
      };

      config = {
        home.packages = [ (packageFor pkgs) ];
        # This is deliberately not xdg.configFile: users can edit inventory in place.
        home.activation.herdsmanInitialConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ ! -e ${lib.escapeShellArg configPath} ] && [ ! -L ${lib.escapeShellArg configPath} ]; then
            run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg (builtins.dirOf configPath)}
            run ${pkgs.coreutils}/bin/install -m 0644 ${initialConfig} ${lib.escapeShellArg configPath}
          fi
        '';
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
            brucenunk.homeManager.herdsman.initialConfig.machines.local = [ "example/repo" ];
            brucenunk.homeManager.herdsman.initialConfig.agentNames = [ "example-agent" ];
          }
        ];
      };
      activationScript = pkgs.writeText "herdsman-seed-test.sh" (
        pkgs.lib.replaceStrings [ home.config.xdg.configHome ] [ "./test-config" ]
          home.config.home.activation.herdsmanInitialConfig.data
      );
    in
    {
      packages.herdsman = package;
      checks.herdsman = package;
      checks.herdsman-home-manager-module = builtins.deepSeq home.activationPackage.drvPath (
        pkgs.runCommand "herdsman-home-manager-module" { } ''
          run() { "$@"; }
          source ${activationScript}
          ${pkgs.python3}/bin/python - <<'PY'
          import tomllib
          with open("test-config/herdsman/config.toml", "rb") as f:
              config = tomllib.load(f)
          assert config["default_base"] == "main"
          assert config["agent_names"] == ["example-agent"]
          assert config["machines"]["local"]["repositories"] == ["example/repo"]
          PY
          printf 'user-owned inventory\n' >test-config/herdsman/config.toml
          source ${activationScript}
          grep -Fx 'user-owned inventory' test-config/herdsman/config.toml
          rm test-config/herdsman/config.toml
          ln -s missing-target test-config/herdsman/config.toml
          source ${activationScript}
          test -L test-config/herdsman/config.toml
          test ! -e test-config/herdsman/missing-target
          ${package}/bin/herdsman --help | grep -F 'herdsman start'
          touch "$out"
        ''
      );
    };
}
