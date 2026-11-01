{ ... }:

{
  flake.modules.homeManager.fonts =
    { pkgs, ... }:

    {
      dconf.settings."org/gnome/desktop/interface" = {
        font-name = "Open Sans 12";
        monospace-font-name = "Iosevka Fixed SS14 12";
      };

      fonts.fontconfig = {
        enable = true;
        defaultFonts.monospace = [ "Iosevka Fixed SS14" ];
      };

      home = {
        packages =
          with pkgs;
          [
            aporetic
            (google-fonts.override { fonts = [ "Bricolage Grotesque" ]; })
            open-sans
          ]
          ++ map (variant: iosevka-bin.override { inherit variant; }) [
            "SGr-IosevkaFixed"
            # JetBrains-inspired shapes, including a dotted zero.
            "SGr-IosevkaFixedSS14"
          ];
      };
    };
}
