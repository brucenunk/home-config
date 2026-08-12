{ ... }:

{
  flake.modules.homeManager.rust =
    { config, pkgs, ... }:

    {
      home.packages = with pkgs; [
        cargo
        clippy
        rustc
        rustfmt
      ];

      home.sessionVariables.CARGO_HOME = "${config.xdg.dataHome}/cargo";
      home.sessionPath = [ "${config.xdg.dataHome}/cargo/bin" ];
    };
}
