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
            # Linux Emacs cannot select Fontconfig's synthetic slant as an italic face.
            # Install matched static upright peers too: otherwise Fontconfig can
            # prefer the static italics to the upstream variable upright font.
            # TODO(bump-nix): Check https://github.com/ateliertriay/bricolage for native
            # italics; once packaged by nixpkgs, verify Emacs selects them and remove
            # this companion package and pkgs/bricolage-oblique.
            (
              if pkgs.stdenv.hostPlatform.isLinux then
                pkgs.callPackage ../../pkgs/bricolage-oblique { }
              else
                # Keep macOS's native slant and optical sizing for the variable font.
                google-fonts.override { fonts = [ "Bricolage Grotesque" ]; }
            )
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
