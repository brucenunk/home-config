{ ... }:

{
  flake.modules.homeManager.niri =
    { pkgs, ... }:

    {
      # Niri installed via nixos-config repo.
      # https://wiki.nixos.org/wiki/Niri/en

      home.packages = with pkgs; [
        xwayland-satellite # xwayland support
      ];

      programs.fuzzel.enable = true; # Super+D in the default setting (app launcher)
      programs.ghostty.enable = true; # Super+T in the default setting (terminal)
      programs.swaylock.enable = true; # Super+Alt+L in the default setting (screen locker)

      services.mako.enable = true; # notification daemon
      services.polkit-gnome.enable = true; # polkit

      xdg.configFile = {
        "niri" = {
          source = ../../config/niri;
          recursive = true;
        };
        "fuzzel/themes" = {
          source = ../../config/fuzzel/themes;
          recursive = true;
        };
        "fuzzel/doric-fuzzel" = {
          source = ../../config/fuzzel/doric-fuzzel;
          executable = true;
        };
      };
    };
}
