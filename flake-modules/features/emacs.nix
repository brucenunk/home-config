{ inputs, ... }:

let
  homeManagerModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      managedServers = config.brucenunk.homeManager.emacs.trampRpc.managedServers;
      spellingDictionaries = with pkgs.hunspellDicts; [
        en_AU
        en_US
      ];

      # Nix owns Emacs package and Tree-sitter parser installation; use-package
      # owns package configuration in config/emacs.
      emacsPackages =
        epkgs: with epkgs; [
          auto-dark
          avy
          bazel
          cape
          consult
          consult-denote
          corfu
          denote
          doric-themes
          editorconfig
          embark
          embark-consult
          envrc
          exec-path-from-shell
          fontaine
          forge
          (import ../../pkgs/ghostel.nix { inherit pkgs epkgs; })
          jinx
          jsonnet-mode
          lin
          magit
          marginalia
          markdown-mode
          mixed-pitch
          nix-ts-mode
          orderless
          pulsar
          rainbow-delimiters
          rego-mode
          spacious-padding
          terraform-mode
          (import ../../pkgs/tramp-rpc.nix { inherit inputs pkgs epkgs; })
          vertico
          wgrep
          ws-butler
          yaml-mode
        ];

      # Keep this curated list aligned with configured languages in
      # config/emacs/init.el rather than installing every grammar from nixpkgs.
      treeSitterGrammars =
        grammars: with grammars; [
          tree-sitter-bash
          tree-sitter-dockerfile
          tree-sitter-go
          tree-sitter-gomod
          tree-sitter-gotmpl
          tree-sitter-gowork
          tree-sitter-hcl
          tree-sitter-json
          tree-sitter-jsonnet
          tree-sitter-markdown
          tree-sitter-markdown-inline
          tree-sitter-nix
          tree-sitter-python
          # Starlark/Bazel would belong here too, but this nixpkgs revision does
          # not expose a tree-sitter-starlark grammar in tree-sitter.builtGrammars.
          tree-sitter-rego
          tree-sitter-yaml
        ];
    in
    {
      options.brucenunk.homeManager.emacs.trampRpc.managedServers = lib.mkOption {
        default = [ ];
        description = "RPC hosts with a preinstalled server; never acquire or transfer binaries for these connections.";
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              host = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Exact host name used in the RPC TRAMP path (including #port if specified).";
              };
              remoteBinaryPath = lib.mkOption {
                # Upstream v0.15.0 passes this directly to the remote shell.
                type = lib.types.strMatching "/[A-Za-z0-9_./+@=-]+";
                description = "Absolute executable path on the remote host, using only shell-safe ASCII letters, digits and _ . / + @ = - (no whitespace or shell metacharacters).";
              };
              user = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Exact RPC user; null applies to any user on this host.";
              };
            };
          }
        );
      };

      config = {
        assertions = [
          {
            assertion =
              lib.length (lib.unique (map (server: { inherit (server) host user; }) managedServers))
              == lib.length managedServers;
            message = "Emacs TRAMP-RPC managedServers must have unique host/user selectors";
          }
          {
            assertion = lib.all (
              server:
              server.user != null
              || lib.length (lib.filter (other: other.host == server.host) managedServers) == 1
            ) managedServers;
            message = "Emacs TRAMP-RPC managedServers must not mix an all-users selector with user-specific selectors for the same host";
          }
        ];

        programs.emacs = {
          enable = true;

          extraPackages =
            epkgs: emacsPackages epkgs ++ [ (epkgs.treesit-grammars.with-grammars treeSitterGrammars) ];

          package = lib.mkDefault pkgs.emacs;
        };

        home.packages = [ pkgs.enchant ] ++ spellingDictionaries;

        home.sessionVariables = {
          # Enchant's Hunspell provider must also find dictionaries when Emacs
          # is launched without a system-wide Hunspell installation.
          DICPATH = lib.makeSearchPath "share/hunspell" spellingDictionaries;
          EDITOR = "emacsclient -c";
          VISUAL = "emacsclient -c";
        };

        xdg.configFile."emacs/early-init.el".source = ../../config/emacs/early-init.el;
        xdg.configFile."emacs/init.el".source = ../../config/emacs/init.el;
        xdg.configFile."emacs/my-lisp".source = ../../config/emacs/my-lisp;
        xdg.configFile."emacs/my-emacs-modules".source = ../../config/emacs/my-emacs-modules;
        xdg.configFile."emacs/tramp-rpc-managed-servers.json".text = builtins.toJSON managedServers;
        xdg.configFile."mermaid/themes".source = ../../config/mermaid/themes;
      };
    };
in
{
  perSystem =
    { lib, pkgs, ... }:

    let
      mkManagedHome =
        servers:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            homeManagerModule
            {
              home.username = "emacs-module-check";
              home.homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then
                  "/Users/emacs-module-check"
                else
                  "/home/emacs-module-check";
              home.stateVersion = "25.05";
              brucenunk.homeManager.emacs.trampRpc.managedServers = servers;
            }
          ];
        };
      testServers = [
        {
          host = "managed.example.invalid";
          user = "rpc-user";
          remoteBinaryPath = "/home/rpc-user/.nix-profile/bin/tramp-rpc-server";
        }
        {
          host = "all-users.example.invalid";
          remoteBinaryPath = "/opt/rpc/bin/tramp-rpc-server";
        }
      ];
      managedHome = mkManagedHome testServers;
      managedConfig = managedHome.config.xdg.configFile."emacs/tramp-rpc-managed-servers.json";
      rejects = servers: !(builtins.tryEval (mkManagedHome servers).activationPackage.drvPath).success;
      pathType =
        (managedHome.options.brucenunk.homeManager.emacs.trampRpc.managedServers.type.getSubOptions [ ])
        .remoteBinaryPath.type;
    in
    {
      checks = {
        emacs-tramp-rpc =
          let
            emacsWithRpc = pkgs.emacs.pkgs.emacsWithPackages (epkgs: [
              (import ../../pkgs/tramp-rpc.nix { inherit inputs pkgs epkgs; })
              epkgs.use-package
              epkgs.magit
              epkgs.envrc
            ]);
          in
          assert
            (mkManagedHome [ ]).config.xdg.configFile."emacs/tramp-rpc-managed-servers.json".text == "[]";
          assert rejects [
            (builtins.head testServers)
            (builtins.head testServers)
          ];
          assert rejects [
            (builtins.head testServers)
            ((builtins.head testServers) // { user = null; })
          ];
          assert lib.all pathType.check [
            "/home/rpc-user/.nix-profile/bin/tramp-rpc-server"
            "/nix/store/abc-server-0.15.0/bin/tramp-rpc-server"
          ];
          assert lib.all (path: !pathType.check path) [
            "relative/server"
            "/opt/RPC Servers/server"
            "/opt/rpc;touch /tmp/file"
            "/opt/$USER/server"
            "/opt/server\ncommand"
            "/opt/'server'"
            "/opt/`command`"
          ];
          pkgs.runCommand "emacs-tramp-rpc-check"
            {
              nativeBuildInputs = [
                emacsWithRpc
                pkgs.git
              ];
            }
            ''
              export HOME="$TMPDIR"
              mkdir -p "$TMPDIR/emacs"
              cp ${managedConfig.source} "$TMPDIR/emacs/tramp-rpc-managed-servers.json"
              export MY_TRAMP_RPC_MANAGED_SERVERS_TEST=1
              emacs --batch -Q --eval "(setq user-emacs-directory \"$TMPDIR/emacs/\")" \
                -L ${../../config/emacs/my-emacs-modules} \
                --load my-emacs-remote-tests \
                --funcall ert-run-tests-batch-and-exit
              touch "$out"
            '';
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
        let
          mkHome =
            package:
            inputs.home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                homeManagerModule
                {
                  home = {
                    username = "emacs-module-check";
                    homeDirectory = "/home/emacs-module-check";
                    stateVersion = "25.05";
                  };
                }
              ]
              ++ lib.optional (package != null) { programs.emacs.package = package; };
            };
          defaultHome = mkHome null;
          emacs31Home = mkHome pkgs.emacs31;
          emacsNoxHome = mkHome pkgs.emacs-nox;
        in
        {
          emacs-home-manager-module =
            assert defaultHome.config.home.sessionVariables.EDITOR == "emacsclient -c";
            assert defaultHome.config.home.sessionVariables.VISUAL == "emacsclient -c";
            assert defaultHome.config.programs.emacs.package.drvPath == pkgs.emacs.drvPath;
            assert emacs31Home.config.programs.emacs.package.drvPath == pkgs.emacs31.drvPath;
            assert emacsNoxHome.config.programs.emacs.package.drvPath == pkgs.emacs-nox.drvPath;
            pkgs.runCommand "emacs-home-manager-module" { } ''
              touch "$out"
            '';
        }
      );
    };

  flake.modules.homeManager.emacs = homeManagerModule;
}
