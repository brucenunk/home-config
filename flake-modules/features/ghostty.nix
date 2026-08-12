{ ... }:

{
  flake.modules.homeManager.ghostty =
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
          default = pkgs.stdenv.isLinux;
          defaultText = lib.literalExpression "pkgs.stdenv.isLinux";
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
              + lib.optionalString pkgs.stdenv.isLinux ''

                quit-after-last-window-closed = false
              ''
              + lib.optionalString (cfg.extraConfig != "") "\n\n${cfg.extraConfig}";
          }
          // lib.optionalAttrs (pkgs.stdenv.isLinux && cfg.canonicalLinuxService.enable) {
            "systemd/user/graphical-session.target.wants/app-com.mitchellh.ghostty.service".source =
              "${cfg.package}/share/systemd/user/app-com.mitchellh.ghostty.service";
          };
      };
    };
}
