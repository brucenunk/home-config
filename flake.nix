{
  description = "James's personal Home Manager configuration and reusable modules";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "git+https://github.com/vic/import-tree.git";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    emacs-tramp-rpc.url = "github:ArthurHeymans/emacs-tramp-rpc/v0.15.0";
    emacs-tramp-rpc.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.url = "github:numtide/llm-agents.nix";
    # Keep llm-agents on a separate nixpkgs input so it can move independently.
    llm-agents.inputs.nixpkgs.follows = "llm-agents-nixpkgs";
    llm-agents-nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    inputs@{ flake-parts, ... }:

    let
      mkPkgs =
        system:
        import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            inputs.llm-agents.overlays.shared-nixpkgs
            (_final: prev: {
              pythonPackagesExtensions =
                prev.pythonPackagesExtensions
                ++ prev.lib.optionals prev.stdenv.hostPlatform.isDarwin [
                  (_pyFinal: pyPrev: {
                    # afdko 5.0.1's test suite currently fails on Darwin, which blocks
                    # packages that only need it as a build tool.
                    afdko = pyPrev.afdko.overridePythonAttrs (_old: {
                      doCheck = false;
                    });
                  })
                ];
            })
          ];
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];

      _module.args = { inherit mkPkgs; };

      perSystem =
        { pkgs, ... }:
        {
          formatter = pkgs.nixfmt-tree;
        };

      imports = [
        {
          # Capability-owned data helpers compose without evaluating Home Manager.
          options.flake.lib = inputs.nixpkgs.lib.mkOption {
            type = inputs.nixpkgs.lib.types.lazyAttrsOf inputs.nixpkgs.lib.types.raw;
            default = { };
          };
        }
        inputs.flake-parts.flakeModules.modules
        (inputs.import-tree ./flake-modules)
        inputs.home-manager.flakeModules.home-manager
        ./hosts/wampa.nix
      ];
    };
}
