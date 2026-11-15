{ ... }:

{
  flake.modules.homeManager.firmware-update-notifier =
    { pkgs, ... }:

    let
      firmwareUpdateNotifier = pkgs.writeShellApplication {
        name = "firmware-update-notifier";
        runtimeInputs = with pkgs; [
          coreutils
          jq
          libnotify
          util-linux
        ];
        text = builtins.readFile ../../config/firmware-update-notifier/firmware-update-notifier.sh;
      };
    in
    {
      systemd.user.services.firmware-update-notifier = {
        Unit = {
          Description = "Notify about newly available firmware updates";
          After = [
            "graphical-session.target"
            "mako.service"
          ];
        };

        Service = {
          Type = "oneshot";
          ExecStart = "${firmwareUpdateNotifier}/bin/firmware-update-notifier";
          TimeoutStartSec = "5min";
        };
      };

      systemd.user.timers.firmware-update-notifier = {
        Unit = {
          Description = "Check local firmware metadata daily";
          PartOf = [ "graphical-session.target" ];
        };

        Timer = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };

        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
}
