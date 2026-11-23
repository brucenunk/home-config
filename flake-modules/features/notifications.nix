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
          # poweralertd marks low battery warnings as critical urgency too.
          "urgency=critical app-name=poweralertd category=power.low".default-timeout = 5000;
        };
      };
    };
}
