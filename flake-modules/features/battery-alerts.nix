{ ... }:

{
  flake.modules.homeManager.battery-alerts =
    { ... }:

    {
      services.poweralertd = {
        enable = true;
        # Use UPower's policy for the laptop, not peripheral battery events.
        extraArgs = [ "-S" ];
      };
    };
}
