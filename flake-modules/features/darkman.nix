{ ... }:

{
  flake.modules.homeManager.darkman =
    { pkgs, lib, ... }:

    let
      doricDesktopTheme = pkgs.writeShellApplication {
        name = "doric-desktop-theme";
        runtimeInputs = with pkgs; [
          coreutils
          darkman
          dconf
          systemd
        ];
        text = builtins.readFile ../../config/darkman/doric-desktop-theme.sh;
      };
    in
    {
      home.packages = [ doricDesktopTheme ];

      services.darkman = {
        enable = true;
        settings = {
          # Use a stable Sydney location rather than depending on a system GeoClue
          # service, which is not managed by this Home Manager configuration.
          lat = -33.8688;
          lng = 151.2093;
          usegeoclue = false;
        };
        scripts.desktop-shell = ''
          ${lib.getExe doricDesktopTheme} "$1"
        '';
      };
    };
}
