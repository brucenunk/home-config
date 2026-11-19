{ inputs, pkgs }:

let
  masterPkgs = pkgs.extend (import (inputs.emacs-overlay + "/overlays/emacs.nix"));
  emacsMaster =
    if pkgs.stdenv.hostPlatform.isDarwin then masterPkgs.emacs-git else masterPkgs.emacs-git-pgtk;
in
emacsMaster.overrideAttrs (
  final: old: {
    # Master already contains the security fix carried by this stable-release patch.
    patches = builtins.filter (
      patch:
      !(pkgs.lib.hasSuffix "fix-arbitrary-code-execution-in-dot-dir-locals-dot-el-handling.patch" (
        toString patch
      ))
    ) (old.patches or [ ]);

    # The overlay's package scope otherwise retains the unmodified Emacs build.
    passthru = old.passthru // {
      pkgs = old.passthru.pkgs.overrideScope (
        _final: _prev: {
          emacs = final.finalPackage;
        }
      );
    };
  }
)
