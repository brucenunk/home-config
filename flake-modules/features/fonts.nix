{ ... }:

{
  flake.modules.homeManager.fonts =
    { pkgs, ... }:

    let
      python313Packages = (pkgs.python313.override {
        packageOverrides = _final: previous: {
          # TODO(bump-nix): Check whether nixpkgs has updated nanoemoji's v0.16.0 source hash; remove this override when it has.
          nanoemoji = previous.nanoemoji.overrideAttrs (_: {
            src = pkgs.fetchFromGitHub {
              owner = "googlefonts";
              repo = "nanoemoji";
              tag = "v0.16.0";
              hash = "sha256-FysyKC01XBnRiur5RR9fcsTxQqE8x0JJHSoe3q6JtKc=";
            };
          });
        };
      }).pkgs;
      jetbrains-mono = pkgs.jetbrains-mono.override { inherit python313Packages; };
    in
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
