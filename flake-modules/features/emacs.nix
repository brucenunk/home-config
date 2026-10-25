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
          doric-themes
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

        xdg.configFile."emacs/early-init.el".source = ../../config/emacs/early-init.el;
        xdg.configFile."emacs/init.el".source = ../../config/emacs/init.el;
        xdg.configFile."emacs/my-lisp".source = ../../config/emacs/my-lisp;
        xdg.configFile."emacs/my-emacs-modules".source = ../../config/emacs/my-emacs-modules;
        xdg.configFile."emacs/sounds/agent-attention.wav".source =
          import ../../pkgs/agent-attention-sound.nix
            { inherit pkgs; };
        xdg.configFile."emacs/tramp-rpc-managed-servers.json".text = builtins.toJSON managedServers;
        xdg.configFile."mermaid/themes".source = ../../config/mermaid/themes;
        xdg.configFile."excali".source = ../../config/excali;
      };
    };
in
{
  perSystem =
    { lib, pkgs, ... }:

    let
      emacsMaster = import ../../pkgs/emacs-master.nix { inherit inputs pkgs; };
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
      checks = {
        emacs-excali =
          let
            emacs = (mkManagedHome [ ]).config.programs.emacs.finalPackage;
          in
          pkgs.runCommand "emacs-excali-check" { nativeBuildInputs = [ emacs ]; } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            mkdir -p "$HOME/.config"
            ln -s ${../../config/excali} "$HOME/.config/excali"
            emacs --batch -Q -L ${../../config/emacs/my-emacs-modules} \
              --load my-emacs-excali-tests --funcall ert-run-tests-batch-and-exit
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
              epkgs.doric-themes
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
              # Never enable configured cleanup during unrelated launcher tests.
              # The dedicated GC suite checks real enablement in isolated state.
              emacs --batch -Q -L ${../../config/emacs/my-emacs-modules} \
                --eval '(progn (require (quote agent-shell-gc)) (advice-add (quote agent-shell-gc-mode) :override (quote ignore)))' \
                -l my-agent-shell --eval '
                (progn
                  (require (quote agent-shell))
                  (unless (and (eq agent-shell-preferred-agent-config (quote pi))
                               agent-shell-prefer-viewport-interaction
                               agent-shell-tramp-mode
                               (eq agent-shell-path-resolver-function
                                   (quote agent-shell-tramp-resolve-path))
                               (eq agent-shell-transcript-file-path-function
                                   (quote my/agent-shell--transcript-file-path))
                               (eq agent-shell-dot-subdir-function
                                   (quote my/agent-shell--dot-subdir))
                               (equal my/agent-shell-transcript-directory
                                      (expand-file-name "~/work/agent-shell/transcripts/" "/")))
                    (error "Agent shell defaults or TRAMP integration are missing"))
                  (unless (version<= agent-shell--shell-maker-minimum-version shell-maker-version)
                    (error "shell-maker is too old: %s" shell-maker-version))
                  (unless (version<= agent-shell--acp-minimum-version acp-package-version)
                    (error "ACP is too old: %s" acp-package-version))
                  (unless (fboundp (quote agent-shell-pi-make-agent-config))
                    (error "Pi integration is missing"))
                  ;; Inspect only launcher autoload forms, without running init.
                  (with-temp-buffer
                    (insert-file-contents "${../../config/emacs/init.el}")
                    (goto-char (point-min))
                    (condition-case nil
                        (while t
                          (let ((form (read (current-buffer))))
                            (when (and (eq (car-safe form) (quote autoload))
                                       (equal (nth 2 form) "my-agent-session"))
                              (eval form))))
                      (end-of-file nil)))
                  (dolist (command (quote (my/agent-session-start-from-file
                                           my/agent-session-start-new-worktree
                                           my/agent-session-start-in-directory)))
                    (unless (and (commandp command) (autoloadp (symbol-function command)))
                      (error "Missing launcher autoload: %s" command)))
                  (when (fboundp (quote my/agent-session-start))
                    (error "Obsolete combined launcher is still autoloaded"))
                  (message "agent-shell %s; shell-maker %s; ACP %s"
                           agent-shell--version shell-maker-version acp-package-version))'
              emacs --batch -Q -l ${agentShellTramp.src}/agent-shell-tramp-tests.el \
                -f ert-run-tests-batch-and-exit
              emacs --batch -Q -l ${agentShellGc.src}/tests/agent-shell-gc-tests.el \
                -f ert-run-tests-batch-and-exit
              emacs --batch -Q -L ${../../config/emacs/my-lisp} -L ${../../config/emacs/my-emacs-modules} \
                --eval '(progn (require (quote agent-shell-gc)) (advice-add (quote agent-shell-gc-mode) :override (quote ignore)))' \
                -l my-agent-session-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q -L ${../../config/emacs/my-emacs-modules} \
                -l my-agent-shell-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q -L ${../../config/emacs/my-emacs-modules} \
                -l my-agent-shell-notifications-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q -L ${../../config/emacs/my-emacs-modules} \
                -l my-emacs-ui-tests -f ert-run-tests-batch-and-exit
              emacs --batch -Q -L ${../../config/emacs/my-emacs-modules} \
                -l my-emacs-completion-tests -f ert-run-tests-batch-and-exit
              touch "$out"
            '';

        emacs-agent-attention-sound = import ../../pkgs/agent-attention-sound.nix { inherit pkgs; };

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
                -L ${../../config/emacs/my-emacs-modules} \
                --load my-emacs-remote-tests \
                --funcall ert-run-tests-batch-and-exit
              MY_TRAMP_RPC_PRELOADED_TEST=1 \
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
            assert defaultHome.config.programs.emacs.package.drvPath == emacsMaster.drvPath;
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
