{
  config,
  inputs,
  mkPkgs,
  ...
}:

let
  pkgs = mkPkgs "x86_64-linux";

  piRelayEndpoint = {
    address = "127.0.0.1";
    path = "/openai/v1";
    port = 18765;
  };
in
{
  flake.homeConfigurations."james@wampa" = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = { inherit inputs; };

    modules = [
      {
        home = {
          homeDirectory = "/home/james";
          stateVersion = "25.05";
          username = "james";
        };

        nix.package = pkgs.nix;
      }

      {
        imports = [
          config.flake.modules.homeManager.packages
          config.flake.modules.homeManager.agents
          config.flake.modules.homeManager.bazel
          config.flake.modules.homeManager.direnv
          config.flake.modules.homeManager.emacs
          config.flake.modules.homeManager.fd
          config.flake.modules.homeManager.fish
          config.flake.modules.homeManager.firmware-update-notifier
          config.flake.modules.homeManager.fonts
          config.flake.modules.homeManager.fzf
          config.flake.modules.homeManager.ghostty
          config.flake.modules.homeManager.git
          config.flake.modules.homeManager.git-maintenance
          config.flake.modules.homeManager.golang
          config.flake.modules.homeManager.hephaestus
          config.flake.modules.homeManager.kube
          config.flake.modules.homeManager.language-servers
          config.flake.modules.homeManager.ripgrep
          config.flake.modules.homeManager.rust
          config.flake.modules.homeManager.pi
          config.flake.modules.homeManager.darkman
          config.flake.modules.homeManager.niri
          config.flake.modules.homeManager.waybar
        ];
      }

      {
        home.packages = with pkgs; [
          clang-tools
          gcc
          google-chrome
          keymapp
          qmk
          spice
          spice-gtk
          usbutils
          vlc
        ];

        home.sessionVariables = {
          AWS_BEDROCK_FORCE_HTTP1 = "1";
          AWS_BEDROCK_SKIP_AUTH = "1";
        };

        brucenunk.homeManager.pi = {
          localEndpoint = piRelayEndpoint;
          models = import ../config/pi/wampa-relay-models.nix {
            bedrockBaseUrl = "http://127.0.0.1:18766/bedrock";
            openAIBaseUrl = "http://127.0.0.1:18765/openai/v1";
          };
          modelsFileName = "pi-models-wampa.json";
          settingsDefaults = ../config/pi/settings-wampa.json;
        };

        programs.emacs.extraConfig = ''
          (with-eval-after-load 'my-agent-pi
            (setq my/agent-pi-model-routes
                  '(("gpt-5.6-sol" . "openai-proxy/gpt-5.6-sol")
                    ("gpt-5.6-terra" . "openai-proxy/gpt-5.6-terra")
                    ("gpt-5.6-luna" . "openai-proxy/gpt-5.6-luna")
                    ("grok-4.6" . "bedrock-proxy/global.xai.grok-4.6")
                    ("fable-5" . "bedrock-proxy/global.anthropic.claude-fable-5")
                    ("opus-5" . "bedrock-proxy/global.anthropic.claude-opus-5")
                    ("sonnet-5" . "bedrock-proxy/global.anthropic.claude-sonnet-5"))
                  my/agent-pi-valid-models
                  '("gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna"
                    "grok-4.6" "fable-5" "opus-5" "sonnet-5")
                  my/agent-pi-valid-thinking-levels
                  '("off" "minimal" "low" "medium" "high" "xhigh" "max")
                  my/agent-pi-minimal-thinking-unsupported-models
                  '("gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna")
                  my/agent-pi-default-model "gpt-5.6-sol"))
        '';

        programs.git.settings.user.email = "bruce.nunk@gmail.com";
      }
    ];
  };
}
