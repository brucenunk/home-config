{ inputs, ... }:

{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        pi-apply-patch-tests =
          pkgs.runCommand "pi-apply-patch-tests" { nativeBuildInputs = [ pkgs.nodejs ]; }
            ''
              node --test ${../../config/pi/extensions/apply-patch}/apply-patch.test.ts
              touch "$out"
            '';

        pi-settings-defaults-tests =
          pkgs.runCommand "pi-settings-defaults-tests"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.shellcheck
              ];
            }
            ''
              shellcheck \
                ${../../config/pi/merge-settings-defaults.sh} \
                ${../../config/pi/merge-settings-defaults.test.sh}
              ${pkgs.bash}/bin/bash ${../../config/pi/merge-settings-defaults.test.sh} \
                ${../../config/pi/merge-settings-defaults.sh} \
                ${pkgs.jq}/bin/jq \
                ${pkgs.bash}/bin/bash \
                ${pkgs.coreutils}/bin
              touch "$out"
            '';
      };
    };

  flake.modules.homeManager.pi =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      cfg = config.brucenunk.homeManager.pi;

      directoryEntries =
        destination: source: expectedType:
        if source == null then
          { }
        else
          lib.mapAttrs' (name: _: {
            name = "${destination}/${name}";
            value.source = source + "/${name}";
          }) (lib.filterAttrs (_: type: type == expectedType) (builtins.readDir source));

      themeEntries = directoryEntries ".pi/agent/themes" cfg.themesDirectory "regular";
      extensionEntries = directoryEntries ".pi/agent/extensions" cfg.extensionsDirectory "directory";
      modelsJson = pkgs.writeText cfg.modelsFileName (builtins.toJSON cfg.models);
    in
    {
      options.brucenunk.homeManager.pi = {
        enable = lib.mkEnableOption "Pi coding agent deployment";

        package = lib.mkOption {
          type = lib.types.package;
          default =
            if pkgs ? "llm-agents" then
              pkgs.llm-agents.pi
            else
              (inputs.llm-agents.overlays.shared-nixpkgs pkgs pkgs).llm-agents.pi;
          defaultText = lib.literalExpression ''
            pkgs.llm-agents.pi or the module's pinned llm-agents overlay applied to pkgs
          '';
          description = "Pi package to install.";
        };

        extensionsDirectory = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Directory of Pi extension directories to deploy.";
        };

        localEndpoint = lib.mkOption {
          description = "Optional local HTTP endpoint used by a private provider adapter.";
          default = null;
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                address = lib.mkOption {
                  type = lib.types.str;
                  description = "Local listener IP address.";
                };
                path = lib.mkOption {
                  type = lib.types.str;
                  description = "HTTP path prefix exposed by the listener.";
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  description = "Local listener port.";
                };
              };
            }
          );
        };

        models = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Pi model catalogue written to models.json.";
        };

        modelsFileName = lib.mkOption {
          type = lib.types.str;
          default = "pi-models.json";
          description = "Store source name for the generated model catalogue.";
        };

        settingsDefaults = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            JSON defaults recursively merged into mutable Pi settings during activation.
            Activation fails without modifying an existing settings file when it is invalid JSON.
          '';
        };

        themesDirectory = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Directory of Pi theme files to deploy.";
        };
      };

      config = lib.mkMerge [
        {
          brucenunk.homeManager.pi = {
            enable = lib.mkDefault true;

            extensionsDirectory = lib.mkDefault ../../config/pi/extensions;
            themesDirectory = lib.mkDefault ../../config/pi/themes;
          };
        }

        (lib.mkIf cfg.enable {
          home.packages = [ cfg.package ];

          home.file =
            themeEntries
            // extensionEntries
            // lib.optionalAttrs (cfg.models != { }) {
              ".pi/agent/models.json".source = modelsJson;
            };

          home.activation.piSettingsDefaults = lib.mkIf (cfg.settingsDefaults != null) (
            lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              ${pkgs.bash}/bin/bash ${../../config/pi/merge-settings-defaults.sh} \
                "$HOME/.pi/agent/settings.json" \
                "${cfg.settingsDefaults}" \
                ${pkgs.jq}/bin/jq \
                ${pkgs.coreutils}/bin/cp \
                ${pkgs.coreutils}/bin/chmod \
                ${pkgs.coreutils}/bin/chown \
                ${pkgs.coreutils}/bin/stat \
                ${pkgs.coreutils}/bin/mv \
                ${pkgs.coreutils}/bin/ln
            ''
          );
        })
      ];
    };
}
