{ ... }:

{
  flake.modules.homeManager.fonts =
    { pkgs, ... }:

    {
      fonts.fontconfig.enable = true;

      home = {
        packages = with pkgs; [
          (google-fonts.override { fonts = [ "Bricolage Grotesque" ]; })
          jetbrains-mono
          open-sans
        ];
      };
    };
}
