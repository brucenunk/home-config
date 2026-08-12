{ ... }:

{
  flake.modules.homeManager.packages =
    { pkgs, lib, ... }:

    {
      home.packages =
        with pkgs;
        [
          # Core CLI tools
          awscli2
          binutils
          cfssl
          cmake
          coreutils
          curl
          diffutils
          dig
          gh
          gnumake
          gnused
          go-jsonnet
          graphviz
          htop
          jq
          jsonnet-bundler
          lsof
          moreutils
          nixfmt
          shellcheck
          shfmt
          tcpdump
          tree
          unixtools.watch
          wget
          yq-go
        ]
        ++ lib.optionals (!stdenv.isDarwin) [
          glib
          wavemon
          iw
        ]
        ++ lib.optionals stdenv.isDarwin [
          fswatch
          glibtool
        ];
    };
}
