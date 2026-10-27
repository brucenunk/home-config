{ epkgs, pkgs }:

# TODO(bump-nix): Remove this override and use epkgs.doric-themes directly once
# nixpkgs/unstable provides Doric 1.4.0 or newer; regenerate the theme catalogues.
epkgs.doric-themes.overrideAttrs (_old: {
  version = "1.4.0";
  src = pkgs.fetchurl {
    url = "https://elpa.gnu.org/packages/doric-themes-1.4.0.tar";
    hash = "sha256-c+SXc62d+QOEiSLE0CsUNZfP/9gR1NfM8skmw6eOpic=";
  };
})
