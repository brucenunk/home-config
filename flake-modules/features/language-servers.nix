{ ... }:

{
  flake.modules.homeManager.language-servers =
    { pkgs, ... }:

    {
      # Keep Eglot's auto-start allowlist in config/emacs/init.el in sync when
      # adding language servers here or in language-specific modules.
      home.packages = with pkgs; [
        bash-language-server
        jsonnet-language-server
        nixd
        regal
        terraform-ls
        tflint
        yaml-language-server
      ];
    };
}
