{ ... }:

{
  flake.modules.homeManager.niri =
    { pkgs, ... }:

    let
      # Downloaded from Adobe Stock's Free collection under its Standard License.
      # Keep the standalone asset out of Git because that license does not permit
      # redistributing the original file.
      wallpaper = pkgs.requireFile {
        name = "AdobeStock_404848752.jpeg";
        sha256 = "sha256-zTKK0diw63b0E3nhnlrC6pW0FLAYu05G6cF6C1rWHgY=";
        message = ''
          The Niri wallpaper must be provisioned from its licensed download.

          Source (Adobe Stock asset 404848752):
          https://stock.adobe.com/uk/images/winter-landscape-of-a-snow-flocked-forest-jackson-hole-lake-fort-custer-state-park-michigan-usa/404848752

          Add the downloaded file to the Nix store with:
            nix-store --add-fixed sha256 /path/to/AdobeStock_404848752.jpeg
        '';
      };
      wallpaperCommand = pkgs.writeShellApplication {
        name = "niri-wallpaper";
        runtimeInputs = [ pkgs.swaybg ];
        text = ''
          exec swaybg --mode fill --image "${wallpaper}"
        '';
      };
    in
    {
      # Niri installed via nixos-config repo.
      # https://wiki.nixos.org/wiki/Niri/en

      home.packages = with pkgs; [
        wallpaperCommand
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
