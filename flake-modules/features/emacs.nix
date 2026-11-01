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
      emacsConfig = import ../../pkgs/emacs-config.nix {
        inherit pkgs;
        emacs = config.programs.emacs.package;
      };
      managedServers = config.brucenunk.homeManager.emacs.trampRpc.managedServers;
      spellingDictionaries = with pkgs.hunspellDicts; [
        en_AU
        en_US
      ];

      # Nix owns Emacs package and Tree-sitter parser installation; use-package
      # owns package configuration in config/emacs.
      emacsPackages =
        epkgs: with epkgs; [
          (import ../../pkgs/agent-shell.nix { inherit pkgs epkgs; })
          (import ../../pkgs/agent-shell-gc.nix { inherit pkgs epkgs; })
          (import ../../pkgs/agent-shell-notifications.nix { inherit pkgs epkgs; })
          (import ../../pkgs/agent-shell-tramp.nix { inherit pkgs epkgs; })
          auto-dark
          avy
          bazel
          cape
          consult
          consult-denote
          corfu
          denote
          diff-hl
          (import ../../pkgs/doric-themes.nix { inherit pkgs epkgs; })
          editorconfig
          embark
          embark-consult
          envrc
          (import ../../pkgs/excali-mode.nix {
            inherit pkgs;
            emacs = epkgs.emacs;
          })
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
          writeroom-mode
          ws-butler
          yaml
          yaml-mode
        ];

      # Keep this curated list aligned with configured languages in
      # config/emacs/my-emacs.org rather than installing every grammar from nixpkgs.
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

          package = lib.mkDefault (import ../../pkgs/emacs-master.nix { inherit inputs pkgs; });
        };

        home.packages = [
          pkgs.enchant
        ]
        ++ spellingDictionaries
        ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.pulseaudio;

        home.sessionVariables = {
          # Enchant's Hunspell provider must also find dictionaries when Emacs
          # is launched without a system-wide Hunspell installation.
          DICPATH = lib.makeSearchPath "share/hunspell" spellingDictionaries;
          EDITOR = "emacsclient -c";
          VISUAL = "emacsclient -c";
        };

        xdg.configFile."emacs/early-init.el".source = "${emacsConfig}/early-init.el";
        xdg.configFile."emacs/init.el".source = "${emacsConfig}/init.el";
        xdg.configFile."emacs/my-emacs.org".source = ../../config/emacs/my-emacs.org;
        xdg.configFile."emacs/my-lisp".source = ../../config/emacs/my-lisp;
        xdg.configFile."emacs/my-emacs-modules".source = "${emacsConfig}/my-emacs-modules";
        xdg.configFile."emacs/sounds/agent-attention.wav".source =
          import ../../pkgs/agent-attention-sound.nix
            { inherit pkgs; };
        xdg.configFile."emacs/tramp-rpc-managed-servers.json".text = builtins.toJSON managedServers;
        xdg.configFile."excali".source = ../../config/excali;
      };
    };
in
{
  perSystem =
    { lib, pkgs, ... }:

    let
      emacsMaster = import ../../pkgs/emacs-master.nix { inherit inputs pkgs; };
      emacsConfig = import ../../pkgs/emacs-config.nix {
        inherit pkgs;
        emacs = emacsMaster;
      };
      emacsTestPaths = "-L ${../../config/emacs/my-lisp} -L ${emacsConfig}/my-emacs-modules -L ${../../config/emacs/tests}";
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
      packages.emacs-master = emacsMaster;
      packages.emacs-config = emacsConfig;
      checks = {
        emacs-literate =
          let
            emacs = (mkManagedHome [ ]).config.programs.emacs.finalPackage;
          in
          pkgs.runCommand "emacs-literate-check"
            {
              nativeBuildInputs = [
                emacs
                pkgs.git
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              export XDG_CONFIG_HOME="$HOME/.config"
              export DICPATH="${
                lib.makeSearchPath "share/hunspell" [
                  pkgs.hunspellDicts.en_AU
                  pkgs.hunspellDicts.en_US
                ]
              }"
              mkdir -p "$XDG_CONFIG_HOME"
              export MY_EMACS_GENERATED=${emacsConfig}
              export MY_EMACS_SOURCE=${../../config/emacs}
              emacs --batch -Q ${emacsTestPaths} \
                -l my-emacs-literate-tests -f ert-run-tests-batch-and-exit
              # Retain Nix site-start so programming-mode spelling fixtures find grammars.
              emacs --batch -q ${emacsTestPaths} \
                -l my-emacs-editing-tests -f ert-run-tests-batch-and-exit
              touch "$out"
            '';

        emacs-denote =
          let
            emacs = (mkManagedHome [ ]).config.programs.emacs.finalPackage;
          in
          pkgs.runCommand "emacs-denote-check" { nativeBuildInputs = [ emacs ]; } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME/.config/emacs"
            emacs --batch -Q ${emacsTestPaths} \
              --eval '(setq user-emacs-directory (expand-file-name "~/.config/emacs/"))' \
              --load my-emacs-denote-tests --load my-denote-task-tests \
              --funcall ert-run-tests-batch-and-exit
            touch "$out"
          '';
        emacs-deferred =
          let
            emacs = (mkManagedHome [ ]).config.programs.emacs.finalPackage;
          in
          pkgs.runCommand "emacs-deferred-check"
            {
              nativeBuildInputs = [
                emacs
                pkgs.git
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              emacs --batch -Q ${emacsTestPaths} \
                --load my-emacs-deferred-tests --funcall ert-run-tests-batch-and-exit
              touch "$out"
            '';
        emacs-mode-selection =
          let
            emacs = (mkManagedHome [ ]).config.programs.emacs.finalPackage;
          in
          pkgs.runCommand "emacs-mode-selection-check" { nativeBuildInputs = [ emacs ]; } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            # Keep Nix site-start for grammar paths; batch skips the user init.
            emacs --batch -q ${emacsTestPaths} \
              --load my-emacs-mode-selection-tests --funcall ert-run-tests-batch-and-exit
            touch "$out"
          '';
        emacs-excali =
          let
            emacs = (mkManagedHome [ ]).config.programs.emacs.finalPackage;
          in
          pkgs.runCommand "emacs-excali-check" { nativeBuildInputs = [ emacs ]; } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            mkdir -p "$HOME/.config"
            ln -s ${../../config/excali} "$HOME/.config/excali"
            emacs --batch -Q ${emacsTestPaths} \
              --load my-emacs-org-excali-tests --funcall ert-run-tests-batch-and-exit
            touch "$out"
          '';
        emacs-agent-shell =
          let
            agentShellGc = import ../../pkgs/agent-shell-gc.nix {
              inherit pkgs;
              epkgs = emacsMaster.pkgs;
            };
            agentShellTramp = import ../../pkgs/agent-shell-tramp.nix {
              inherit pkgs;
              epkgs = emacsMaster.pkgs;
            };
            emacsWithAgent = emacsMaster.pkgs.emacsWithPackages (epkgs: [
              (import ../../pkgs/agent-shell.nix { inherit pkgs epkgs; })
              (import ../../pkgs/agent-shell-notifications.nix { inherit pkgs epkgs; })
              agentShellGc
              agentShellTramp
              epkgs.denote
              epkgs.yaml
              epkgs.vertico
              epkgs.marginalia
              epkgs.orderless
              epkgs.corfu
              epkgs.cape
              epkgs.consult
              epkgs.embark
              epkgs.embark-consult
              epkgs.avy
              epkgs.mixed-pitch
              epkgs.markdown-mode
              epkgs.rainbow-delimiters
              (import ../../pkgs/doric-themes.nix { inherit pkgs epkgs; })
              epkgs.auto-dark
              epkgs.fontaine
              epkgs.spacious-padding
              epkgs.writeroom-mode
              epkgs.pulsar
              epkgs.lin
              (import ../../pkgs/tramp-rpc.nix { inherit inputs pkgs epkgs; })
              epkgs.use-package
            ]);
          in
          pkgs.runCommand "emacs-agent-shell-check"
            {
              nativeBuildInputs = [
                emacsWithAgent
                pkgs.git
                pkgs.curl
              ];
            }
            ''
              export HOME="$TMPDIR"
              emacs --batch -Q -l ${agentShellTramp.src}/agent-shell-tramp-tests.el \
                -f ert-run-tests-batch-and-exit
              emacs --batch -Q -l ${agentShellGc.src}/tests/agent-shell-gc-tests.el \
                -f ert-run-tests-batch-and-exit
              emacs --batch -Q ${emacsTestPaths} \
                --eval '(progn (require (quote agent-shell-gc)) (advice-add (quote agent-shell-gc-mode) :override (quote ignore)))' \
                -l my-agent-session-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q ${emacsTestPaths} \
                -l my-agent-shell-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q ${emacsTestPaths} \
                -l my-agent-shell-notifications-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q ${emacsTestPaths} \
                -l my-emacs-ui-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q ${emacsTestPaths} \
                -l my-emacs-completion-tests -f ert-run-tests-batch-and-exit
              touch "$out"
            '';

        emacs-tramp-rpc =
          let
            emacsWithRpc = emacsMaster.pkgs.emacsWithPackages (epkgs: [
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
                ${emacsTestPaths} \
                --load my-emacs-remote-tests \
                --funcall ert-run-tests-batch-and-exit
              MY_TRAMP_RPC_PRELOADED_TEST=1 \
                emacs --batch -Q --eval "(setq user-emacs-directory \"$TMPDIR/emacs/\")" \
                ${emacsTestPaths} \
                --load my-emacs-remote-tests \
                --funcall ert-run-tests-batch-and-exit
              touch "$out"
            '';
      };
    };

  flake.modules.homeManager.emacs = homeManagerModule;
}
