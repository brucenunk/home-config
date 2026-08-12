{ ... }:

{
  flake.modules.homeManager.direnv =
    { config, pkgs, ... }:

    {
      programs.direnv = {
        package =
          if pkgs.stdenv.hostPlatform.isDarwin then
            pkgs.direnv.overrideAttrs (_: {
              doCheck = false;
            })
          else
            pkgs.direnv;
        enable = true;

        config = {
          global = {
            warn_timeout = "10m";
          };
          whitelist = {
            prefix = [
              "${config.home.homeDirectory}/work"
            ];
          };
        };
        enableBashIntegration = true;
        nix-direnv.enable = true;
      };
    };
}
