{ inputs, lib, ... }:

let
  validComponent =
    value:
    builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" value != null
    && !(lib.hasInfix ".." value)
    && !(lib.hasSuffix ".lock" value)
    && !(lib.hasSuffix "." value);
  repositoryType = lib.types.attrsOf (
    lib.types.submodule {
      options = {
        defaultBranch = lib.mkOption {
          type = lib.types.addCheck lib.types.str (value: lib.all validComponent (lib.splitString "/" value));
          default = "main";
          description = "The repository's default branch; setting this does not check out or rename a branch.";
        };
        path = lib.mkOption {
          type = lib.types.strMatching "/.*";
          description = "Absolute path on this machine to a checkout/worktree or bare repository (the git -C directory).";
        };
      };
    }
  );

  repositoryOptions = {
    repositories = lib.mkOption {
      type = repositoryType;
      default = { };
      apply =
        repositories:
        if
          lib.all (
            slug:
            builtins.match "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+" slug != null
            && lib.all (part: part != "." && part != "..") (lib.splitString "/" slug)
          ) (builtins.attrNames repositories)
        then
          repositories
        else
          throw "Git repository keys must be owner/repository slugs";
      description = "Repositories hosted on this machine, keyed by owner/repository slug.";
    };
  };
  maintenancePaths = git: map (repository: repository.path) (builtins.attrValues git.repositories);
  maintenanceSettings = {
    maintenance = {
      auto = false;
      strategy = "incremental";

      gc.enabled = true;
      gc.schedule = "weekly";
      commit-graph.schedule = "hourly";
      prefetch.schedule = "hourly";
      loose-objects.schedule = "daily";
      incremental-repack.schedule = "daily";
    };
  };
  homeManagerModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      repositories = maintenancePaths config.brucenunk.homeManager.git;
    in
    {
      options.brucenunk.homeManager.git = repositoryOptions;
      config = {
        home.packages = [ pkgs.gh ];

        programs.git = {
          enable = true;

          settings = {
            alias = {
              ci = "commit";
              co = "checkout";
              l = "lg -n 10";
              lg = "log --graph";
              st = "status";
              tags = ''for-each-ref --format="%(refname)" --sort=-taggerdate refs/tags'';
            };

            core = {
              editor = "emacsclient";
              fsmonitor = true;
              untrackedcache = true;
            };

            credential = {
              "https://gist.github.com".helper = [
                ""
                "!${pkgs.gh}/bin/gh auth git-credential"
              ];
              "https://github.com".helper = [
                ""
                "!${pkgs.gh}/bin/gh auth git-credential"
              ];
            };

            format.pretty = "%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset";
            init.defaultBranch = "main";
            push.autoSetupRemote = true;
            user.name = "James Lee";
          };

          # Home Manager owns the Linux timers and Darwin launchd schedules.
          maintenance = {
            enable = lib.mkDefault (repositories != [ ]);
            inherit repositories;
            # Linux: weekly runs include daily tasks, so leave Saturday to GC.
            # Darwin's native launchd policy already runs weekly on Sunday.
            timers = lib.mkDefault {
              hourly = "*-*-* 1..23:53:00";
              daily = "Mon..Fri,Sun *-*-* 1:00:00";
              weekly = "Sat *-*-* 1:00:00";
            };
          };
          includes = lib.optionals config.programs.git.maintenance.enable (
            lib.concatMap (
              repository:
              map
                (gitdir: {
                  condition = "gitdir:${gitdir}";
                  contents = maintenanceSettings;
                })
                [
                  repository
                  "${repository}/"
                ]
            ) repositories
          );
        };
      };
    };
in
{
  flake.lib.git = { inherit repositoryOptions maintenancePaths; };
  flake.modules.homeManager.git = homeManagerModule;

  perSystem =
    { pkgs, ... }:
    let
      home = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          homeManagerModule
          {
            home = {
              username = "git-module-check";
              homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then "/Users/git-module-check" else "/home/git-module-check";
              stateVersion = "25.05";
            };
            brucenunk.homeManager.git.repositories = {
              "example/repo".path = "/test-repositories/checkouts/main";
              "example/bare" = {
                path = "/test-repositories/backing/repo.git";
                defaultBranch = "master";
              };
            };
          }
        ];
      };
      git = home.config.brucenunk.homeManager.git;
      disabled = home.extendModules {
        modules = [ { programs.git.maintenance.enable = false; } ];
      };
    in
    {
      checks.git-home-manager-module =
        assert
          git.repositories."example/repo" == {
            path = "/test-repositories/checkouts/main";
            defaultBranch = "main";
          };
        assert
          maintenancePaths git == [
            "/test-repositories/backing/repo.git"
            "/test-repositories/checkouts/main"
          ];
        assert home.config.programs.git.maintenance.enable;
        assert home.config.programs.git.maintenance.repositories == maintenancePaths git;
        assert disabled.config.programs.git.includes == [ ];
        assert
          if pkgs.stdenv.hostPlatform.isDarwin then
            home.config.launchd.agents ? "git-maintenance-weekly"
          else
            home.config.systemd.user.timers."git-maintenance@weekly".Timer.OnCalendar == "Sat *-*-* 1:00:00"
            &&
              home.config.systemd.user.timers."git-maintenance@daily".Timer.OnCalendar
              == "Mon..Fri,Sun *-*-* 1:00:00"
            && home.config.systemd.user.timers."git-maintenance@hourly".Timer.OnCalendar == "*-*-* 1..23:53:00";
        builtins.deepSeq [ home.activationPackage.drvPath disabled.activationPackage.drvPath ] (
          pkgs.runCommand "git-home-manager-module" { } ''
            export HOME="$PWD/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$PWD/gitconfig"
            mkdir -p "$HOME" work/backing work/checkouts
            ${pkgs.gnused}/bin/sed "s|/test-repositories|$PWD/work|g" \
              ${home.config.xdg.configFile."git/config".source} > "$GIT_CONFIG_GLOBAL"
            git() { ${lib.getExe home.config.programs.git.package} -c core.fsmonitor=false "$@"; }
            bare="$PWD/work/backing/repo.git"
            source="$PWD/work/checkouts/main"
            git init --bare -q "$bare"
            git init -q "$source"
            test "$(git --git-dir="$bare" config --get maintenance.strategy)" = incremental
            test "$(git -C "$bare" config --get maintenance.strategy)" = incremental
            test "$(git -C "$source" config --get maintenance.strategy)" = incremental
            test "$(git -C "$source" config --get maintenance.gc.enabled)" = true
            test "$(git -C "$source" config --get maintenance.gc.schedule)" = weekly
            git -C "$source" -c user.email=check@example.invalid commit -q --allow-empty -m fixture
            git -C "$source" worktree add -q --detach "$PWD/task" HEAD
            test "$(git -C "$PWD/task" config --get maintenance.strategy)" = incremental
            touch "$out"
          ''
        );
    };
}
