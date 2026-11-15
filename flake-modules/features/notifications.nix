{ ... }:

{
  flake.modules.homeManager.notifications =
    { ... }:

    {
      services.mako = {
        enable = true;
        settings = {
          default-timeout = 5000;
          ignore-timeout = true;
          "urgency=critical".default-timeout = 0;
        };
      };
    };
}
