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
    }
  );
in
assert pkgs.lib.assertMsg (
  rpc.version == version
) "TRAMP-RPC's Lisp version must match the hash-pinned release servers";
rpc
