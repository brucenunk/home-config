{ ... }:

{
  flake.modules.homeManager.agents =
    { lib, pkgs, ... }:

    let
      skillNames = [
        "bump-nix"
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
    in
    {
      home.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
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
}
