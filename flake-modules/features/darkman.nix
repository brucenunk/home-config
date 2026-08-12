{ ... }:

{
  flake.modules.homeManager.darkman =
    { pkgs, lib, ... }:

    let
      doricDesktopTheme = pkgs.writeShellApplication {
        name = "doric-desktop-theme";
        runtimeInputs = with pkgs; [
          coreutils
          darkman
          systemd
        ];
        text = ''
          mode="''${1:-}"

          if [ "$mode" = "--startup" ]; then
            mode=""
            attempts=0
            while [ "$attempts" -lt 20 ]; do
              if mode="$(darkman get 2>/dev/null)"; then
                break
              fi
              attempts=$((attempts + 1))
              sleep 0.25
            done
            mode="''${mode:-dark}"
          fi

          case "$mode" in
            light) theme="doric-marble" ;;
            dark) theme="doric-obsidian" ;;
            *)
              printf 'usage: doric-desktop-theme light|dark|--startup\n' >&2
              exit 2
              ;;
          esac

          niri_config="$HOME/.config/niri/config-$mode.kdl"
          if command -v niri >/dev/null 2>&1 && [ -f "$niri_config" ]; then
            # Darkman may start before Niri publishes its socket, so the daemon's
            # original environment can lack NIRI_SOCKET even after the user manager
            # has imported it. Recover the current value before sending the reload.
            manager_environment=""
            if manager_environment="$(systemctl --user show-environment 2>/dev/null)"; then
              manager_niri_socket="$(
                printf '%s\n' "$manager_environment" |
                  while IFS='=' read -r name value; do
                    if [ "$name" = "NIRI_SOCKET" ]; then
                      printf '%s\n' "$value"
                      break
                    fi
                  done
              )"
              if [ -n "$manager_niri_socket" ]; then
                NIRI_SOCKET="$manager_niri_socket"
                export NIRI_SOCKET
              fi
            fi

            if [ -n "''${NIRI_SOCKET:-}" ]; then
              if ! niri msg action load-config-file \
                --path "$niri_config" >/dev/null; then
                printf 'failed to load Niri %s theme\n' "$mode" >&2
              fi
            else
              printf 'cannot load Niri %s theme: NIRI_SOCKET is unavailable\n' \
                "$mode" >&2
            fi
          fi

          waybar_theme="$HOME/.config/waybar/doric-waybar-theme"
          if [ -x "$waybar_theme" ]; then
            "$waybar_theme" "$theme"
          fi
        '';
      };
    in
    {
      home.packages = [ doricDesktopTheme ];

      services.darkman = {
        enable = true;
        settings = {
          # Use a stable Sydney location rather than depending on a system GeoClue
          # service, which is not managed by this Home Manager configuration.
          lat = -33.8688;
          lng = 151.2093;
          usegeoclue = false;
        };
        scripts.desktop-shell = ''
          ${lib.getExe doricDesktopTheme} "$1"
        '';
      };

      # Keep Niri's packaged portal mappings while making Darkman the
      # colour-scheme provider for portal-aware applications.
      xdg.configFile."xdg-desktop-portal/niri-portals.conf".text = ''
        [preferred]
        default=gnome;gtk;
        org.freedesktop.impl.portal.Access=gtk;
        org.freedesktop.impl.portal.Notification=gtk;
        org.freedesktop.impl.portal.Secret=gnome-keyring;
        org.freedesktop.impl.portal.Settings=darkman;
      '';
    };
}
