{ ... }:

{
  flake.modules.homeManager.python =
    { pkgs, ... }:

    {
      home.packages = with pkgs; [
        (python3.withPackages (
          p: with p; [
            python-lsp-ruff
            python-lsp-server
            ruff
          ]
        ))
      ];
    };
}
