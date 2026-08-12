{ ... }:

{
  flake.modules.homeManager.ollama =
    { lib, ... }:
    {
      services.ollama = {
        enable = true;
        host = lib.mkDefault "127.0.0.1";
      };
    };
}
