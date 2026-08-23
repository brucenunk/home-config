{ ... }:

{
  flake.modules.homeManager.niri =
    { pkgs, lib, ... }:

    let
      # Downloaded from Adobe Stock's Free collection under its Standard License.
      # Keep the standalone asset out of Git because that license does not permit
      # redistributing the original file.
      lightWallpaper = pkgs.requireFile {
        name = "AdobeStock_404848752.jpeg";
        sha256 = "sha256-zTKK0diw63b0E3nhnlrC6pW0FLAYu05G6cF6C1rWHgY=";
        message = ''
          The light Niri wallpaper must be provisioned from its licensed download.

          Source (Adobe Stock asset 404848752):
          https://stock.adobe.com/uk/images/winter-landscape-of-a-snow-flocked-forest-jackson-hole-lake-fort-custer-state-park-michigan-usa/404848752

          Add the downloaded file to the Nix store with:
            nix-store --add-fixed sha256 /path/to/AdobeStock_404848752.jpeg
        '';
      };
      darkWallpaper = pkgs.requireFile {
        name = "AdobeStock_473845992.jpeg";
        sha256 = "sha256-JtOiXdaoddEY5ZuQToxY90DvmvqgLvHHF6qNJGnVGCg=";
        message = ''
          The dark Niri wallpaper must be provisioned from its licensed download.

          Source (Adobe Stock asset 473845992):
          https://stock.adobe.com/uk/images/dark-forest-in-mist-foggy-day-mysterious-atmosphere/473845992

          Add the downloaded file to the Nix store with:
            nix-store --add-fixed sha256 /path/to/AdobeStock_473845992.jpeg
        '';
      };
    in
    {
      # Niri installed via nixos-config repo.
      # https://wiki.nixos.org/wiki/Niri/en

      home.packages = [ pkgs.xwayland-satellite ]; # xwayland support

      systemd.user.services = {
        niri-wallpaper-light = {
          Unit = {
            Description = "Niri light wallpaper";
            PartOf = [ "graphical-session.target" ];
            Conflicts = [ "niri-wallpaper-dark.service" ];
          };
          Service = {
            ExecStart = "${lib.getExe pkgs.swaybg} --mode fill --image ${lightWallpaper}";
            Restart = "on-failure";
            RestartSec = 1;
          };
        };
        niri-wallpaper-dark = {
          Unit = {
            Description = "Niri dark wallpaper";
            PartOf = [ "graphical-session.target" ];
            Conflicts = [ "niri-wallpaper-light.service" ];
          };
          Service = {
            ExecStart = "${lib.getExe pkgs.swaybg} --mode fill --image ${darkWallpaper}";
            Restart = "on-failure";
            RestartSec = 1;
          };
        };
      };

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
