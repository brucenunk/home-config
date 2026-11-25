{
  description = "James's personal Home Manager configuration and reusable modules";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "git+https://github.com/vic/import-tree.git";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/home-manager";
    };

    # flake.lock pins both the Emacs master snapshot and Lisp package metadata.
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      flake = false;
    };

    emacs-tramp-rpc = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:ArthurHeymans/emacs-tramp-rpc/v0.15.0";
    };

    # Keep llm-agents on a separate nixpkgs input so it can move independently.
    llm-agents-nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    llm-agents = {
      inputs.nixpkgs.follows = "llm-agents-nixpkgs";
      url = "github:numtide/llm-agents.nix";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:

    let
      mkPkgs =
        system:
        import inputs.nixpkgs {
          inherit system;

          config.allowUnfreePredicate =
            pkg:
            builtins.elem (inputs.nixpkgs.lib.getName pkg) [
              "AdobeStock_345609645.jpeg"
              "AdobeStock_376846912.jpeg"
              "google-chrome"
              "keymapp"
            ];

          overlays = [
            # LLM agents for quicker updates to agents.
            inputs.llm-agents.overlays.shared-nixpkgs

            # Emacs overlay for quicker updates to emacs and emacs packages.
            (import (inputs.emacs-overlay + "/overlays/package.nix"))

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

      imports = with inputs; [
        {
          # Capability-owned data helpers compose without evaluating Home Manager.
          options.flake.lib = nixpkgs.lib.mkOption {
            type = nixpkgs.lib.types.lazyAttrsOf nixpkgs.lib.types.raw;
            default = { };
          };
        }

        flake-parts.flakeModules.modules
        home-manager.flakeModules.home-manager

        # Import flake modules.
        (import-tree ./flake-modules)

        # Import hosts.
        ./hosts/wampa.nix
      ];
    };
}
