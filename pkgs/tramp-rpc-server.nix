{ pkgs }:

let
  version = "0.15.0";
  assets = {
    "x86_64-linux" = {
      target = "x86_64-unknown-linux-musl";
      hash = "sha256-FxDdtfrliyH5MxfNthl2LwFrOcid/qFR0lnxLwX2xfY=";
    };
    "aarch64-linux" = {
      target = "aarch64-unknown-linux-musl";
      hash = "sha256-VpQqiIQdxrxmd9UZyfGWyQNZAf6K1xO9NC5rnqQyVDg=";
    };
  };
in
{
  inherit version assets;

  # These are release archives, not cross-compiled Rust packages. A Darwin
  # builder can unpack both Linux binaries for bundling in its Emacs package.
  packages = pkgs.lib.mapAttrs (
    system: asset:
    let
      archive = pkgs.fetchurl {
        url = "https://github.com/ArthurHeymans/emacs-tramp-rpc/releases/download/v${version}/tramp-rpc-server-${asset.target}-${version}.tar.gz";
        inherit (asset) hash;
      };
    in
    pkgs.runCommand "tramp-rpc-server-${system}-${version}"
      {
        passthru = {
          inherit version archive;
          targetSystem = system;
        };
      }
      ''
        mkdir -p "$out/bin"
        tar -xzf ${archive} -C "$out/bin"
        chmod 755 "$out/bin/tramp-rpc-server"
      ''
  ) assets;
}
