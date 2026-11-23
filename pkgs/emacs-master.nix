{ inputs, pkgs }:

let
  masterPkgs = pkgs.extend (import (inputs.emacs-overlay + "/overlays/emacs.nix"));
  emacsMaster =
    if pkgs.stdenv.hostPlatform.isDarwin then masterPkgs.emacs-git else masterPkgs.emacs-git-pgtk;
in
emacsMaster.overrideAttrs (
  final: old: {
    # Keep the overlay's revision and source hash, but avoid Savannah's unreliable HTTP endpoint.
    src = old.src.override { url = "https://github.com/emacsmirror/emacs.git"; };

    # Master already contains the security fix carried by this stable-release patch.
    patches = builtins.filter (
      patch:
      !(pkgs.lib.hasSuffix "fix-arbitrary-code-execution-in-dot-dir-locals-dot-el-handling.patch" (
        toString patch
      ))
    ) (old.patches or [ ]);

    # Temporarily revert c9f0656d47 (Emacs bug#79204): its Cairo image cache
    # introduces an outline around the graphical agent-shell header on PGTK.
    # TODO(bump-nix): Test the graphical agent-shell header on PGTK at 2×
    # scaling without this revert; drop the revert once the outline is gone.
    postPatch =
      (old.postPatch or "")
      + pkgs.lib.optionalString (!pkgs.stdenv.hostPlatform.isDarwin) ''
        patch --reverse --fuzz=0 -p1 < ${./emacs-cairo-image-cache.patch}
      '';

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
