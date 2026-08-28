{ ... }:

{
  flake.modules.homeManager.fonts =
    { pkgs, ... }:

    {
      dconf.settings."org/gnome/desktop/interface".font-name = "Open Sans 11";

      fonts.fontconfig.enable = true;

      home = {
        packages = with pkgs; [
          aporetic
          (google-fonts.override { fonts = [ "Bricolage Grotesque" ]; })
          jetbrains-mono
          maple-mono.truetype
          open-sans
        ];
      };
    };
}
