{
  inputs,
  pkgs,
  epkgs,
}:

let
  version = "0.15.0";
  linuxAssets = {
    "x86_64-linux" = {
      target = "x86_64-unknown-linux-musl";
      hash = "sha256-FxDdtfrliyH5MxfNthl2LwFrOcid/qFR0lnxLwX2xfY=";
    };
    "aarch64-linux" = {
      target = "aarch64-unknown-linux-musl";
      hash = "sha256-VpQqiIQdxrxmd9UZyfGWyQNZAf6K1xO9NC5rnqQyVDg=";
    };
  };
  serverPackages = pkgs.lib.mapAttrsToList (system: asset: {
    inherit system;
    package = pkgs.runCommand "tramp-rpc-server-${system}-${version}" { } ''
      mkdir -p "$out/bin"
      tar -xzf ${
        pkgs.fetchurl {
          url = "https://github.com/ArthurHeymans/emacs-tramp-rpc/releases/download/v${version}/tramp-rpc-server-${asset.target}-${version}.tar.gz";
          inherit (asset) hash;
        }
      } -C "$out/bin"
      chmod 755 "$out/bin/tramp-rpc-server"
    '';
  }) linuxAssets;

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
