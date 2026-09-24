{ inputs, mkPkgs, ... }:

let
  taskLaunchSkill = ../../config/agents/skills/herdr-task-launch;
  fallbackPiPackage =
    pkgs:
    if pkgs ? llm-agents then
      pkgs.llm-agents.pi
    else
      (inputs.llm-agents.overlays.shared-nixpkgs pkgs pkgs).llm-agents.pi;
  mkStartTask =
    pkgs: piPackage:
    pkgs.writeShellApplication {
      name = "start-task";
      runtimeInputs = [ piPackage ];
      text = ''
        if [ "$#" -eq 0 ]; then
          printf 'usage: start-task "<specific task request>"\n' >&2
          exit 2
        fi

        case "$*" in
          *[![:space:]]*) ;;
          *)
            printf 'start-task requires a non-empty task request\n' >&2
            exit 2
            ;;
        esac

        if [ "''${HERDR_ENV:-}" != 1 ]; then
          printf 'start-task must run from a Local Herdr pane (HERDR_ENV=1 is required)\n' >&2
          exit 1
        fi

        if [ -z "''${HERDR_WORKSPACE_ID:-}" ] \
          || [ -z "''${HERDR_PANE_ID:-}" ] \
          || [ -z "''${HERDR_SOCKET_PATH:-}" ] \
          || [ ! -S "$HERDR_SOCKET_PATH" ]; then
          printf 'start-task cannot find the Local Herdr control context for this pane\n' >&2
          exit 1
        fi

        request=$(printf '%s\n\nHuman task request: %s' \
          'Load and follow the herdr-task-launch skill for this one-shot request.' \
          "$*")

        exec pi -p --no-session \
          --no-approve \
          --no-context-files \
          --no-extensions \
          --no-prompt-templates \
          --no-skills \
          --skill ${taskLaunchSkill} \
          -- \
          "$request"
      '';
    };
  mkFinishTask =
    {
      pkgs,
      quitTimeout ? 30,
    }:
    pkgs.writeShellApplication {
      name = "finish-task";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
      ];
      text = builtins.replaceStrings [ "@quitTimeout@" ] [ (toString quitTimeout) ] (
        builtins.readFile ../../config/agents/finish-task.sh
      );
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
      skillNames = [
        "herdr-task-launch"
        "pull-request"
        "review"
        "task-workflow-v3"
      ];

      skillEntries = lib.listToAttrs (
        map (skillName: {
          name = ".agents/skills/${skillName}";
          value.source = ../../config/agents/skills/${skillName};
        }) skillNames
      );

      soxDictationInspector = pkgs.runCommand "sox-dictation-inspector" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.sox}/bin/sox $out/bin/sox
      '';

      josip = import ../../pkgs/josip.nix { inherit pkgs; };
      piPackage =
        if
          lib.hasAttrByPath [
            "brucenunk"
            "homeManager"
            "pi"
            "package"
          ] options
        then
          config.brucenunk.homeManager.pi.package
        else
          fallbackPiPackage pkgs;
      startTask = mkStartTask pkgs piPackage;
      finishTask = mkFinishTask { inherit pkgs; };
    in
    {
      home.packages = [
        finishTask
        startTask
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        soxDictationInspector
        josip
      ];

      home.file = skillEntries // {
        ".codex/AGENTS.md".source = ../../config/codex/AGENTS.md;

        "work/AGENTS.md" = {
          source = ../../work/AGENTS.md;
          force = true;
        };
        "work/EMACS-SERVER.md" = {
          source = ../../work/EMACS-SERVER.md;
          force = true;
        };
        "work/REPO-SETUP.md" = {
          source = ../../work/REPO-SETUP.md;
          force = true;
        };
        "work/TASKS.md" = {
          source = ../../work/TASKS.md;
          force = true;
        };
        "work/brucenunk/AGENTS.md" = {
          source = ../../work/brucenunk/AGENTS.md;
          force = true;
        };
      };
    };
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      checkedPkgs = mkPkgs system;
      startTask = mkStartTask checkedPkgs (fallbackPiPackage checkedPkgs);
      finishTask = mkFinishTask { pkgs = checkedPkgs; };

      identity = {
        home.username = "agents-module-check";
        home.homeDirectory =
          if pkgs.stdenv.hostPlatform.isDarwin then
            "/Users/agents-module-check"
          else
            "/home/agents-module-check";
        home.stateVersion = "25.05";
      };
      plainHome = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          homeManagerModule
          identity
        ];
      };

      configuredPi = pkgs.writeShellScriptBin "pi" "exit 0";
      configuredStartTask = mkStartTask pkgs configuredPi;
      configuredFinishTask = mkFinishTask { inherit pkgs; };
      configuredHome = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          homeManagerModule
          identity
          {
            options.brucenunk.homeManager.pi.package = pkgs.lib.mkOption {
              type = pkgs.lib.types.package;
            };
            config.brucenunk.homeManager.pi.package = configuredPi;
          }
        ];
      };
    in
    {
      checks = {
        agents-plain-nixpkgs-home-manager =
          assert plainHome.activationPackage.drvPath != "";
          assert builtins.elem (mkStartTask pkgs (fallbackPiPackage pkgs)) plainHome.config.home.packages;
          assert builtins.elem configuredStartTask configuredHome.config.home.packages;
          assert builtins.elem (mkFinishTask { inherit pkgs; }) plainHome.config.home.packages;
          assert builtins.elem configuredFinishTask configuredHome.config.home.packages;
          pkgs.runCommand "agents-plain-nixpkgs-home-manager-check" { } ''
            grep -F '${configuredPi}/bin' ${configuredStartTask}/bin/start-task
            touch "$out"
          '';

        start-task = pkgs.runCommand "start-task-check" { } ''
          grep -F 'exec pi -p --no-session' ${startTask}/bin/start-task
          grep -F -- '--no-approve' ${startTask}/bin/start-task
          grep -F -- '--no-context-files' ${startTask}/bin/start-task
          grep -F -- '--no-extensions' ${startTask}/bin/start-task
          grep -F -- '--no-prompt-templates' ${startTask}/bin/start-task
          grep -F -- '--no-skills' ${startTask}/bin/start-task
          grep -F -- '--skill ${taskLaunchSkill}' ${startTask}/bin/start-task
          if grep -F -- '--print' ${startTask}/bin/start-task; then
            echo 'start-task must use Pi short print flag -p' >&2
            exit 1
          fi

          if ${startTask}/bin/start-task >no-request.out 2>&1; then
            echo 'start-task accepted a missing task request' >&2
            exit 1
          fi
          grep -F 'usage: start-task' no-request.out

          if env -u HERDR_ENV ${startTask}/bin/start-task '   ' \
            >empty-request.out 2>&1; then
            echo 'start-task accepted an empty task request' >&2
            exit 1
          fi
          grep -F 'non-empty task request' empty-request.out

          if env -u HERDR_ENV ${startTask}/bin/start-task 'Start a task' \
            >outside-herdr.out 2>&1; then
            echo 'start-task ran outside Herdr' >&2
            exit 1
          fi
          grep -F 'HERDR_ENV=1 is required' outside-herdr.out

          if env \
            -u HERDR_WORKSPACE_ID \
            -u HERDR_PANE_ID \
            -u HERDR_SOCKET_PATH \
            HERDR_ENV=1 \
            ${startTask}/bin/start-task 'Start a task' \
            >missing-context.out 2>&1; then
            echo 'start-task ran without a Local Herdr control context' >&2
            exit 1
          fi
          grep -F 'cannot find the Local Herdr control context' \
            missing-context.out
          touch "$out"
        '';

        herdr-task-launch = pkgs.runCommand "herdr-task-launch-check" { } ''
          export TASK_LAUNCH_SKILL=${taskLaunchSkill}/SKILL.md
          ${pkgs.bash}/bin/bash ${../../config/agents/tests/herdr-task-launch.sh}
          touch "$out"
        '';

        finish-task =
          let
            testFinishTask = mkFinishTask {
              inherit pkgs;
              quitTimeout = 1;
            };
          in
          pkgs.runCommand "finish-task-check"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              export FINISH_TASK=${testFinishTask}/bin/finish-task
              ${pkgs.bash}/bin/bash ${../../config/agents/tests/finish-task.sh}
              grep -F 'worktree remove --workspace' ${finishTask}/bin/finish-task
              if grep -F -- 'worktree remove --force' ${finishTask}/bin/finish-task; then
                echo 'finish-task must not force worktree removal' >&2
                exit 1
              fi
              touch "$out"
            '';
      };
    };

  flake.modules.homeManager.agents = homeManagerModule;
}
