{
  inputs,
  pkgs,
  epkgs,
}:

let
  release = import ./tramp-rpc-server.nix { inherit pkgs; };
  inherit (release) version;
  serverPackages = pkgs.lib.mapAttrsToList (system: package: {
    inherit system package;
  }) release.packages;

  # Keep upstream's compatible Lisp dependencies without imposing an overlay
  # on consumers. Supplying serverPackages replaces ALL default Rust builds.
  rpcPkgs = pkgs.extend inputs.emacs-tramp-rpc.overlays.default;
  rpc = (
    (rpcPkgs.emacsPackagesFor epkgs.emacs).tramp-rpc.override {
      inherit serverPackages;
      melpaBuild =
        args:
        let
          package = epkgs.melpaBuild args;
        in
        if args.pname != "tramp" then
          package
        else
          package.overrideAttrs (old: {
            # Emacs master's built-in TRAMP no longer defines all of 2.8.2's
            # autoloaded constants. Load this package's own before native compilation.
            postInstall =
              builtins.replaceStrings
                [ "-f batch-native-compile" ]
                [
                  "--load $out/share/emacs/site-lisp/elpa/tramp-${args.version}/tramp-autoloads.el -f batch-native-compile"
                ]
                old.postInstall;
          });
    }
  );
in
assert pkgs.lib.assertMsg (
  rpc.version == version
) "TRAMP-RPC's Lisp version must match the hash-pinned release servers";
rpc
