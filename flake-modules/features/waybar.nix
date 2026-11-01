let
  doricWaybarThemes = {
    xdg.configFile."waybar/themes" = {
      source = ../../config/waybar/themes;
      recursive = true;
    };
  };
in
{
  flake.modules.homeManager = {
    doric-waybar-themes = doricWaybarThemes;

    waybar =
      { pkgs, ... }:

      {
        imports = [ doricWaybarThemes ];

        home.packages = [ pkgs.util-linux ];

        programs.waybar = {
          enable = true;

          settings = [
            {
              layer = "top";
              position = "bottom";
              height = 38;
              spacing = 8;
              reload_style_on_change = true;

              modules-right = [
                "pulseaudio"
                "custom/separator"
                "network"
                "custom/separator"
                "battery"
                "tray"
                "custom/separator"
                "clock"
              ];

              "custom/separator" = {
                format = "·";
                tooltip = false;
              };

              clock = {
                format = "{:%a %d %b  %H:%M}";
                tooltip-format = "<big>{:%B %Y}</big>\n<tt><small>{calendar}</small></tt>";
              };

              pulseaudio = {
                format = "Vol {volume}%";
                format-muted = "Muted";
                on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
                on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05+ -l 1.0";
                on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05-";
              };

              network = {
                format-wifi = "{essid} {signalStrength}%";
                format-ethernet = "Ethernet";
                format-disconnected = "Offline";
                tooltip-format = "{ifname}: {ipaddr}/{cidr}";
                tooltip-format-wifi = "{essid} ({signalStrength}%)\n{ipaddr}/{cidr}";
                tooltip-format-disconnected = "Network disconnected";
              };

              battery = {
                states = {
                  warning = 30;
                  critical = 15;
                };
                format = "Bat {capacity}%";
                format-charging = "Bat {capacity}% +";
                format-plugged = "Bat {capacity}% AC";
                tooltip-format = "{timeTo} at {power} W";
              };

              tray = {
                icon-size = 16;
                spacing = 8;
              };
            }
          ];
        };

        xdg.configFile = {
          "waybar/style.css".source = ../../config/waybar/style.css;
          "waybar/doric-waybar" = {
            source = ../../config/waybar/doric-waybar;
            executable = true;
          };
          "waybar/doric-waybar-theme" = {
            source = ../../config/waybar/doric-waybar-theme;
            executable = true;
          };
        };
      };
  };
}
