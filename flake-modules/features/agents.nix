{ inputs, ... }:

let
  homeManagerModule =
    {
      lib,
      ...
    }:

    let
      skillNames = [
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
    in
    {
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
    { pkgs, ... }:
    let
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

    in
    {
      checks = {
        agents-plain-nixpkgs-home-manager =
          assert plainHome.activationPackage.drvPath != "";
          assert builtins.all
            (
              skillName:
              plainHome.config.home.file.".agents/skills/${skillName}".source
              == ../../config/agents/skills/${skillName}
            )
            [
              "pull-request"
              "review"
              "task-workflow-v3"
            ];
          assert plainHome.config.home.file."work/AGENTS.md".source == ../../work/AGENTS.md;
          assert plainHome.config.home.file."work/TASKS.md".source == ../../work/TASKS.md;
          assert plainHome.config.home.file."work/EMACS-SERVER.md".source == ../../work/EMACS-SERVER.md;
          assert
            plainHome.config.home.file."work/brucenunk/AGENTS.md".source == ../../work/brucenunk/AGENTS.md;
          assert plainHome.config.home.file.".codex/AGENTS.md".source == ../../config/codex/AGENTS.md;
          pkgs.runCommand "agents-plain-nixpkgs-home-manager-check" { } ''
            touch "$out"
          '';
      };
    };

  flake.modules.homeManager.agents = homeManagerModule;
}
