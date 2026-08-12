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
  piRelayBaseUrl = "http://${piRelayEndpoint.address}:${toString piRelayEndpoint.port}${piRelayEndpoint.path}";
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
          zen-browser
        ];

        brucenunk.homeManager.pi = {
          localEndpoint = piRelayEndpoint;
          models = import ../config/pi/wampa-relay-models.nix { baseUrl = piRelayBaseUrl; };
          modelsFileName = "pi-models-wampa.json";
          settingsDefaults = ../config/pi/settings-wampa.json;
        };

        programs.emacs.extraConfig = ''
          (with-eval-after-load 'my-agent-pi
            (setq my/agent-pi-model-routes
                  '(("gpt-5.6-sol" . "openai-proxy/gpt-5.6-sol")
                    ("gpt-5.6-terra" . "openai-proxy/gpt-5.6-terra")
                    ("gpt-5.6-luna" . "openai-proxy/gpt-5.6-luna"))
                  my/agent-pi-valid-models
                  '("gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna")
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
