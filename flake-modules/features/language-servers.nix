{ ... }:

{
  flake.modules.homeManager.language-servers =
    { pkgs, ... }:

    let
      jsonnetLsp = pkgs.buildGoModule rec {
        pname = "jsonnet-lsp";
        version = "v0.2.12";

        src = pkgs.fetchFromGitHub {
          hash = "sha256-WwC5NQWSnn5pO/uhj8gES50ha0ATtKXjtauuji8gssg=";
          owner = "carlverge";
          repo = pname;
          rev = version;
        };

        vendorHash = "sha256-YDnyVcsgGF9JbzabRV2P7JnUv/wlTJWsBMNtEc2kN90=";
      };
      starlarkLsp = pkgs.buildGoModule rec {
        pname = "starlark-lsp";
        version = "84c13fe";

        src = pkgs.fetchFromGitHub {
          hash = "sha256-EliRobYSjdI2pgA1jFLpGQ8pRFcLJzz8HxCKjyl2ceI=";
          owner = "tilt-dev";
          repo = pname;
          rev = version;
        };

        vendorHash = "sha256-9g0oG3kEJoNzjx5Hdih6TlOby1qDUBqZOEMyV1+2iOg=";
      };
    in
    {
      # Keep Eglot's auto-start allowlist in config/emacs/init.el in sync when
      # adding language servers here or in language-specific modules.
      home.packages = with pkgs; [
        bash-language-server
        jsonnetLsp
        jsonnet-language-server
        lua-language-server
        nixd
        nls
        regal
        starlarkLsp
        terraform-ls
        tflint
        yaml-language-server
      ];
    };
}
