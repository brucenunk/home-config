{ ... }:

{
  flake.modules.homeManager.git-maintenance =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      cfg = config.brucenunk.homeManager.gitMaintenance;

      maintenanceSettings = {
        maintenance = {
          auto = false;
          strategy = "incremental";

          gc.enabled = false;
          commit-graph.schedule = "hourly";
          prefetch.schedule = "hourly";
          loose-objects.schedule = "daily";
          incremental-repack.schedule = "daily";
        };
      };

      gitMaintenance = pkgs.writeShellScript "git-maintenance" ''
        set -eu

        schedule="''${1:-}"
        case "$schedule" in
          hourly|daily) ;;
          *)
            echo "usage: $0 {hourly|daily}" >&2
            exit 2
            ;;
        esac

        lockFile="''${TMPDIR:-/tmp}/home-manager-git-maintenance.lock"
        exec /usr/bin/lockf -k "$lockFile" \
          ${lib.getExe config.programs.git.package} \
          -c credential.interactive=false \
          -c core.askPass=true \
          for-each-repo --keep-going --config=maintenance.repo \
          maintenance run --schedule="$schedule"
      '';
    in
    {
      options.brucenunk.homeManager.gitMaintenance.repositories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Absolute Git worktree paths registered for scheduled maintenance.";
      };

      config = lib.mkIf (pkgs.stdenv.isDarwin && cfg.repositories != [ ]) {
        programs.git = {
          enable = true;

          includes = lib.concatMap (
            repository:
            map
              (gitDirectory: {
                condition = "gitdir:${gitDirectory}";
                contents = maintenanceSettings;
              })
              [
                "${repository}/.git"
                "${repository}/.git/**"
              ]
          ) cfg.repositories;

          settings.maintenance.repo = cfg.repositories;
        };

        launchd.agents = {
          "git-maintenance-hourly" = {
            enable = true;
            config = {
              Label = "org.git-scm.git.hourly";
              ProgramArguments = [
                "${gitMaintenance}"
                "hourly"
              ];
              ProcessType = "Background";
              LowPriorityIO = true;
              StartCalendarInterval = map (Hour: {
                inherit Hour;
                Minute = 40;
              }) (lib.range 1 23);
            };
          };

          "git-maintenance-daily" = {
            enable = true;
            config = {
              Label = "org.git-scm.git.daily";
              ProgramArguments = [
                "${gitMaintenance}"
                "daily"
              ];
              ProcessType = "Background";
              LowPriorityIO = true;
              StartCalendarInterval = {
                Hour = 0;
                Minute = 55;
              };
            };
          };
        };

        home.activation.removeLegacyGitMaintenanceWeekly =
          lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
            ''
              weeklyAgent="$HOME/Library/LaunchAgents/org.git-scm.git.weekly.plist"
              if [[ -e "$weeklyAgent" ]]; then
                verboseEcho "Removing the legacy Git-generated weekly maintenance agent"
                run /bin/launchctl bootout "gui/$UID/org.git-scm.git.weekly" 2>/dev/null || true
                run rm -f "$weeklyAgent"
              fi
            '';
      };
    };
}
