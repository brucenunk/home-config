{ inputs, ... }:

let
  homeManagerModule =
    {
      lib,
      ...
    }:

    let
      skillNames = [
        "review"
        "task-workflow"
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
        ".pi/agent/AGENTS.md" = {
          source = ../../config/pi/AGENTS.md;
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
              "review"
              "task-workflow"
            ];
          assert !(builtins.hasAttr ".agents/skills/pull-request" plainHome.config.home.file);
          assert plainHome.config.home.file.".pi/agent/AGENTS.md".source == ../../config/pi/AGENTS.md;
          assert !(builtins.hasAttr "work/AGENTS.md" plainHome.config.home.file);
          assert plainHome.config.home.file."work/TASKS.md".source == ../../work/TASKS.md;
          assert plainHome.config.home.file."work/EMACS-SERVER.md".source == ../../work/EMACS-SERVER.md;
          assert
            plainHome.config.home.file."work/brucenunk/AGENTS.md".source == ../../work/brucenunk/AGENTS.md;
          assert !(builtins.hasAttr ".codex/AGENTS.md" plainHome.config.home.file);
          pkgs.runCommand "agents-plain-nixpkgs-home-manager-check" { } ''
            touch "$out"
          '';
      };
    };

  flake.modules.homeManager.agents = homeManagerModule;
}
