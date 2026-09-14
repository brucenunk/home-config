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
      cfg = config.brucenunk.homeManager.ghostty;

      ghosttyThemeEntries = lib.mapAttrs' (name: _: {
        name = "ghostty/themes/${name}";
        value.source = ../../config/ghostty/themes/${name};
      }) (lib.filterAttrs (_: type: type == "regular") (builtins.readDir ../../config/ghostty/themes));
    in

    {
      options.brucenunk.homeManager.ghostty = {
        package = lib.mkOption {
          type = lib.types.package;
          default = if pkgs.stdenv.targetPlatform.isDarwin then pkgs.ghostty-bin else pkgs.ghostty;
          defaultText = lib.literalExpression ''
            if pkgs.stdenv.targetPlatform.isDarwin then pkgs.ghostty-bin else pkgs.ghostty
          '';
          description = "Ghostty package to install.";
        };

        canonicalLinuxService.enable = lib.mkOption {
          type = lib.types.bool;
          default = pkgs.stdenv.hostPlatform.isLinux;
          defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.isLinux";
          description = ''
            Whether to link Ghostty's packaged user service into the graphical session target.
          '';
        };

        extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Consumer-owned configuration appended to the shared Ghostty configuration.";
        };
      };

      config = {
        home.packages = [ cfg.package ];

        xdg.configFile =
          ghosttyThemeEntries
          // {
            "ghostty/config".text =
              builtins.readFile ../../config/ghostty/config
              + lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''

                quit-after-last-window-closed = false
              ''
              + lib.optionalString (cfg.extraConfig != "") "\n\n${cfg.extraConfig}";
          }
          // lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux && cfg.canonicalLinuxService.enable) {
            "systemd/user/graphical-session.target.wants/app-com.mitchellh.ghostty.service".source =
              "${cfg.package}/share/systemd/user/app-com.mitchellh.ghostty.service";
          };
      };
    };
in
{
  perSystem =
    { lib, pkgs, ... }:

    let
      home = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          homeManagerModule
          {
            home = {
              username = "ghostty-module-check";
              homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then
                  "/Users/ghostty-module-check"
                else
                  "/home/ghostty-module-check";
              stateVersion = "25.05";
            };

            brucenunk.homeManager.ghostty = {
              package = pkgs.hello;

              canonicalLinuxService.enable = false;
              extraConfig = "font-size = 12";
            };
          }
        ];
      };
      ghosttyConfig = home.config.xdg.configFile."ghostty/config".text;
      ghosttyThemeNames = builtins.filter (name: lib.hasPrefix "ghostty/themes/" name) (
        builtins.attrNames home.config.xdg.configFile
      );
    in
    {
      checks.ghostty-home-manager-module =
        assert builtins.elem pkgs.hello home.config.home.packages;
        assert lib.hasSuffix "\n\nfont-size = 12" ghosttyConfig;
        assert
          ghosttyThemeNames == [
            "ghostty/themes/doric-marble"
            "ghostty/themes/doric-obsidian"
          ];
        assert
          !(
            home.config.xdg.configFile
            ? "systemd/user/graphical-session.target.wants/app-com.mitchellh.ghostty.service"
          );
        pkgs.runCommand "ghostty-home-manager-module" { } ''
          touch "$out"
        '';
    };

  flake.modules.homeManager.ghostty = homeManagerModule;
}
