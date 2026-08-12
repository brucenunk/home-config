{ ... }:

{
  flake.modules.homeManager.fzf =
    { lib, ... }:
    {
      programs.fzf = {
        enable = true;
        defaultCommand = lib.mkDefault "fd --type f --strip-cwd-prefix";
      };
    };
}
