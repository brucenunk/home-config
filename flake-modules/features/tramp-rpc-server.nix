{ inputs, ... }:

let
  overlay =
    final: prev:
    let
      release = import ../../pkgs/tramp-rpc-server.nix { pkgs = final; };
      system = prev.stdenv.hostPlatform.system;
    in
    prev.lib.optionalAttrs (builtins.hasAttr system release.assets) {
      tramp-rpc-server = release.packages.${system};
    };

  homeManagerModule =
    { lib, pkgs, ... }:
    let
      release = import ../../pkgs/tramp-rpc-server.nix { inherit pkgs; };
      system = pkgs.stdenv.hostPlatform.system;
      supported = builtins.hasAttr system release.assets;
    in
    {
      assertions = [
        {
          assertion = supported;
          message = "tramp-rpc-server supports only x86_64-linux and aarch64-linux release binaries";
        }
      ];
      home.packages = lib.optional supported (pkgs.tramp-rpc-server or release.packages.${system});
    };
in
{
  flake.overlays.tramp-rpc = overlay;
  flake.modules.homeManager.tramp-rpc-server = homeManagerModule;

  perSystem =
    { lib, pkgs, ... }:
    let
      release = import ../../pkgs/tramp-rpc-server.nix { inherit pkgs; };
      # Evaluate architecture selection without realizing foreign derivations.
      packageSets = lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "riscv64-linux" ] (
        system:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ overlay ];
        }
      );
      mkHome =
        packages:
        inputs.home-manager.lib.homeManagerConfiguration {
          pkgs = packages;
          modules = [
            homeManagerModule
            {
              home.username = "rpc-server-check";
              home.homeDirectory = "/home/rpc-server-check";
              home.stateVersion = "25.05";
            }
          ];
        };
      linuxHomes = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: mkHome packageSets.${system});
      selectedPackage = pkgs.runCommand "rpc-server-overlay-selection-check" { } "touch $out";
      overriddenHome = mkHome (
        packageSets.x86_64-linux.extend (
          _final: _prev: {
            tramp-rpc-server = selectedPackage;
          }
        )
      );
    in
    {
      checks.tramp-rpc-server =
        assert lib.all
          (
            system:
            let
              home = linuxHomes.${system};
              package = packageSets.${system}.tramp-rpc-server;
              fallbackHome = mkHome (import inputs.nixpkgs { inherit system; });
            in
            package.targetSystem == system
            && package.version == release.version
            && lib.elem package home.config.home.packages
            && lib.any (p: p.drvPath == package.drvPath) fallbackHome.config.home.packages
            && !home.config.programs.emacs.enable
          )
          [
            "x86_64-linux"
            "aarch64-linux"
          ];
        assert !(packageSets.aarch64-darwin ? tramp-rpc-server);
        assert !(packageSets.riscv64-linux ? tramp-rpc-server);
        assert !(builtins.tryEval (mkHome packageSets.aarch64-darwin).activationPackage.drvPath).success;
        assert lib.elem selectedPackage overriddenHome.config.home.packages;
        pkgs.runCommand "tramp-rpc-server-check" { } ''
          test -x ${release.packages.x86_64-linux}/bin/tramp-rpc-server
          test -x ${release.packages.aarch64-linux}/bin/tramp-rpc-server
          touch "$out"
        '';
    };
}
