{ inputs, lib, ... }:

let
  modelsOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    apply = models: builtins.deepSeq (projectModels models) models;
    description = "Pi model configuration, including private provider connection fields.";
  };

  # Match Pi 1.0.0's pi-ai getSupportedThinkingLevels, not transport guesses.
  thinkingLevels =
    model:
    if !(model.reasoning or false) then
      [ "off" ]
    else
      lib.filter
        (
          level:
          let
            mapping = model.thinkingLevelMap or { };
          in
          if mapping ? ${level} then mapping.${level} != null else level != "xhigh" && level != "max"
        )
        [
          "off"
          "minimal"
          "low"
          "medium"
          "high"
          "xhigh"
          "max"
        ];

  projectModels =
    models:
    let
      references = lib.concatLists (
        lib.mapAttrsToList (
          provider: definition:
          if provider == "" || lib.hasInfix "/" provider then
            throw "Pi catalogue provider names must be non-empty and contain no slash"
          else
            map (
              model:
              let
                override = (definition.modelOverrides or { }).${model.id} or { };
                effective = model // {
                  reasoning = override.reasoning or (model.reasoning or false);
                  thinkingLevelMap = (model.thinkingLevelMap or { }) // (override.thinkingLevelMap or { });
                };
              in
              if (model.type or "chat") != "chat" then
                throw "Pi models.json definitions are chat-only; non-chat models require runtime extensions"
              else if model.id == "" then
                throw "Pi catalogue model IDs must be non-empty"
              else
                {
                  name = "${provider}/${model.id}";
                  thinkingLevels = thinkingLevels effective;
                }
            ) (definition.models or [ ])
        ) (models.providers or { })
      );
    in
    if
      builtins.length references != builtins.length (lib.unique (map (model: model.name) references))
    then
      throw "Pi catalogue contains duplicate model references"
    else
      references;

  homeManagerModule =
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
      settingsDefaultsJson = pkgs.writeText "pi-settings-defaults.json" (
        builtins.toJSON (
          lib.recursiveUpdate (builtins.fromJSON (builtins.readFile ../../config/pi/settings.json)) (
            builtins.fromJSON (builtins.readFile cfg.settingsDefaults)
          )
        )
      );
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

        models = modelsOption;

        modelsFileName = lib.mkOption {
          type = lib.types.str;
          default = "pi-models.json";
          description = "Store source name for the generated model catalogue.";
        };

        settingsDefaults = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = ../../config/pi/settings.json;
          description = ''
            JSON defaults layered over shared Pi defaults, then recursively merged
            into mutable Pi settings during activation. Host defaults take precedence
            over shared defaults. Set null to disable settings activation.
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
                "${settingsDefaultsJson}" \
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
in
{
  flake.lib.pi = { inherit modelsOption projectModels thinkingLevels; };

  perSystem =
    { pkgs, ... }:
    let
      wampaRelayModels = import ../../config/pi/wampa-relay-models.nix {
        bedrockBaseUrl = "http://127.0.0.1:18766/bedrock";
        openAIBaseUrl = "http://127.0.0.1:18765/openai/v1";
      };
      wampaOpenAIModels = wampaRelayModels.providers.openai-proxy.models;
      wampaBedrockModels = wampaRelayModels.providers.bedrock-proxy.models;
      projectionModels.providers = wampaRelayModels.providers // {
        example = {
          api = "openai-responses";
          baseUrl = "https://private-endpoint.invalid";
          apiKey = "!private-credential-command";
          headers.Secret = "private-header";
          models = [
            {
              id = "vendor/model";
              reasoning = false;
            }
          ];
          modelOverrides."vendor/model" = {
            reasoning = true;
            thinkingLevelMap = {
              off = null;
              minimal = null;
              xhigh = "xhigh";
              max = "max";
            };
          };
        };
      };
      projectedModels = projectModels projectionModels;
      # Test the pinned loader directly, without changing the deployed Pi package.
      piNode = home.config.brucenunk.homeManager.pi.package.override { useBun = false; };
      wampaSettings = builtins.fromJSON (builtins.readFile ../../config/pi/settings-wampa.json);
      gpt6ModelIds = [
        "gpt-6-astra"
        "gpt-6-sol"
        "gpt-6-luna"
        "gpt-6.1-sol"
      ];
      gpt6ModelsValid = builtins.all (
        id:
        builtins.any (
          model:
          model.id == id
          && model.contextWindow == 1050000
          && model.maxTokens == 128000
          && model.reasoning
          && builtins.elem "text" model.input
          && builtins.elem "image" model.input
          && model.thinkingLevelMap.minimal == null
          && (
            if id == "gpt-6-astra" || id == "gpt-6.1-sol" then
              model.thinkingLevelMap.off == null
            else
              model.thinkingLevelMap.off == "none"
          )
        ) wampaOpenAIModels
      ) gpt6ModelIds;
      newBedrockModelsValid =
        builtins.all
          (
            id:
            builtins.any (
              model:
              model.id == id
              && model.contextWindow == (if id == "global.xai.grok-4.7" then 500000 else 1000000)
              && model.maxTokens == (if id == "global.xai.grok-4.7" then 500000 else 128000)
              && builtins.elem "text" model.input
              && model.reasoning == (id != "global.xai.grok-4.7")
            ) wampaBedrockModels
          )
          [
            "global.xai.grok-4.7"
            "global.anthropic.claude-sonnet-5-5"
          ];

      mkHome =
        piConfig:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            homeManagerModule
            {
              home = {
                username = "pi-module-check";
                homeDirectory =
                  if pkgs.stdenv.hostPlatform.isDarwin then "/Users/pi-module-check" else "/home/pi-module-check";
                stateVersion = "25.05";
              };

              brucenunk.homeManager.pi = piConfig;
            }
          ];
        };
      home = mkHome {
        enable = false;
        extensionsDirectory = null;
        themesDirectory = null;
      };
      defaultsHome = mkHome { };
      hostDefaultsHome = mkHome {
        settingsDefaults = ../../config/pi/settings-wampa.json;
      };
      disabledDefaultsHome = mkHome { settingsDefaults = null; };
      overriddenDefaultsHome = mkHome {
        settingsDefaults = builtins.toFile "pi-settings-override.json" ''{"tuiMode":"fullscreen"}'';
      };
      expectedDefaults = pkgs.writeText "pi-settings-defaults.json" (
        builtins.toJSON { tuiMode = "regular"; }
      );
      expectedHostDefaults = pkgs.writeText "pi-settings-defaults.json" (
        builtins.toJSON (wampaSettings // { tuiMode = "regular"; })
      );
      expectedOverride = pkgs.writeText "pi-settings-defaults.json" (
        builtins.toJSON { tuiMode = "fullscreen"; }
      );
      usesDefaults =
        expected: configuration:
        pkgs.lib.hasInfix (builtins.unsafeDiscardStringContext (toString expected)) configuration.config.home.activation.piSettingsDefaults.data;
    in
    {
      checks = {
        pi-settings-policy =
          assert usesDefaults expectedDefaults defaultsHome;
          assert usesDefaults expectedHostDefaults hostDefaultsHome;
          assert !(disabledDefaultsHome.config.home.activation ? piSettingsDefaults);
          assert usesDefaults expectedOverride overriddenDefaultsHome;
          pkgs.runCommand "pi-settings-policy" { nativeBuildInputs = [ pkgs.jq ]; } ''
            jq -e '.tuiMode == "regular" and (has("externalEditor") | not)' ${expectedDefaults}
            jq -e '.tuiMode == "regular" and .defaultProvider == "openai-proxy" and .defaultModel == "gpt-6.1-sol"' ${expectedHostDefaults}
            touch "$out"
          '';

        pi-apply-patch-tests =
          pkgs.runCommand "pi-apply-patch-tests" { nativeBuildInputs = [ pkgs.nodejs ]; }
            ''
              node --test ${../../config/pi/extensions/apply-patch}/apply-patch.test.ts
              cp -r ${../../config/pi/extensions/apply-patch} ./apply-patch
              chmod -R u+w ./apply-patch
              ln -s ${piNode}/lib/node_modules/@earendil-works/pi-coding-agent/node_modules ./apply-patch/node_modules
              node --test ./apply-patch/renderers.test.ts
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

        pi-home-manager-module =
          assert !home.config.brucenunk.homeManager.pi.enable;
          assert !(builtins.elem home.config.brucenunk.homeManager.pi.package home.config.home.packages);
          assert home.config.brucenunk.homeManager.pi.extensionsDirectory == null;
          assert home.config.brucenunk.homeManager.pi.themesDirectory == null;
          assert
            thinkingLevels { reasoning = true; } == [
              "off"
              "minimal"
              "low"
              "medium"
              "high"
            ];
          assert
            !(builtins.tryEval (
              builtins.deepSeq (projectModels {
                providers.example.models = [
                  {
                    id = "image";
                    type = "image";
                  }
                ];
              }) true
            )).success;
          pkgs.runCommand "pi-home-manager-module" { } ''
            ${pkgs.nodejs}/bin/node --input-type=module - ${pkgs.writeText "pi-projection-fixture.json" (builtins.toJSON projectionModels)} ${pkgs.writeText "pi-projection-expected.json" (builtins.toJSON projectedModels)} <<'JS'
            import assert from "node:assert/strict";
            import { readFileSync } from "node:fs";
            import { composeModelProvider } from "${piNode}/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/provider-composer.js";
            import { getSupportedThinkingLevels } from "${piNode}/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/models.js";
            const fixture = JSON.parse(readFileSync(process.argv[2], "utf8"));
            const expected = JSON.parse(readFileSync(process.argv[3], "utf8"));
            const config = { getProvider: provider => fixture.providers[provider] };
            const actual = Object.keys(fixture.providers).sort().flatMap(provider =>
              composeModelProvider(provider, undefined, config).getModels().map(model => ({
                name: `''${provider}/''${model.id}`,
                thinkingLevels: getSupportedThinkingLevels(model),
              })));
            assert.deepEqual(actual, expected);
            assert(expected.every(model => Object.keys(model).sort().join(",") === "name,thinkingLevels"));
            assert(!JSON.stringify(expected).includes("private-"));
            JS
            touch "$out"
          '';

        pi-wampa-settings =
          assert wampaSettings.defaultTools == [ "+codemode" ];
          assert wampaSettings.terminal.showTerminalProgress;
          pkgs.runCommand "pi-wampa-settings" { } ''
            touch "$out"
          '';

        pi-wampa-gpt6-models =
          assert gpt6ModelsValid;
          assert newBedrockModelsValid;
          assert wampaSettings.defaultProvider == "openai-proxy";
          assert wampaSettings.defaultModel == "gpt-6.1-sol";
          pkgs.runCommand "pi-wampa-gpt6-models" { } ''
            touch "$out"
          '';
      };
    };

  flake.modules.homeManager.pi = homeManagerModule;
}
