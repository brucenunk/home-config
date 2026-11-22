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
  flake.lib.skills.bump-nix = ../../.agents/skills/bump-nix;
  flake.modules.homeManager.agents = homeManagerModule;
}
