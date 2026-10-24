{ inputs, pkgs }:

let
  masterPkgs = pkgs.extend (import (inputs.emacs-overlay + "/overlays/emacs.nix"));
in
if pkgs.stdenv.hostPlatform.isDarwin then masterPkgs.emacs-git else masterPkgs.emacs-git-pgtk
