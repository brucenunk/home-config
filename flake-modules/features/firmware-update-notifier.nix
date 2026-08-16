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
        text = ''
          state_home="''${XDG_STATE_HOME:-$HOME/.local/state}"
          state_file="''${FWUPD_NOTIFIER_STATE_FILE:-$state_home/firmware-update-notifier/releases.json}"
          fwupdmgr="''${FWUPD_NOTIFIER_FWUPDMGR:-/run/current-system/sw/bin/fwupdmgr}"
          notify_send="''${FWUPD_NOTIFIER_NOTIFY_SEND:-${pkgs.libnotify}/bin/notify-send}"

          state_directory=$(dirname "$state_file")
          mkdir -p "$state_directory"
          chmod 700 "$state_directory"

          exec 9>"$state_directory/check.lock"
          if ! flock -n 9; then
            printf 'firmware update check already running\n' >&2
            exit 0
          fi

          query_status=0
          fwupd_output="$("$fwupdmgr" get-updates \
            --json \
            --no-metadata-check \
            --no-remote-check 2>/dev/null)" || query_status=$?

          case "$query_status" in
            0|2) ;;
            *)
              printf 'firmware update query failed (status %s)\n' \
                "$query_status" >&2
              exit 1
              ;;
          esac

          if [ -z "$fwupd_output" ]; then
            printf 'firmware update query returned no output (status %s)\n' \
              "$query_status" >&2
            exit 1
          fi

          if ! current_releases="$(
            printf '%s\n' "$fwupd_output" |
              jq -ce '
                def nonempty_string:
                  type == "string" and length > 0;

                if type != "object" or (.Devices | type) != "array" then
                  error("invalid fwupd JSON shape")
                else
                  [
                    .Devices[]
                    | if type != "object"
                        or (.DeviceId | nonempty_string | not)
                        or (.Releases | type) != "array"
                      then error("invalid fwupd device")
                      else .
                      end
                    | . as $device
                    | .Releases[]
                    | if type != "object"
                        or (.ReleaseId | nonempty_string | not)
                        or (.Version | nonempty_string | not)
                      then error("invalid fwupd release")
                      else [ $device.DeviceId, .ReleaseId, .Version ]
                      end
                  ]
                  | unique
                end
              ' 2>/dev/null
          )"; then
            printf 'firmware update query returned invalid JSON\n' >&2
            exit 1
          fi

          write_state() {
            umask 077
            temporary_state=$(mktemp "$state_file.tmp.XXXXXX")
            trap 'rm -f "$temporary_state"' EXIT HUP INT TERM
            printf '%s\n' "$current_releases" >"$temporary_state"
            mv "$temporary_state" "$state_file"
            trap - EXIT HUP INT TERM
          }

          if [ ! -e "$state_file" ]; then
            write_state
            exit 0
          fi

          if ! previous_releases="$(
            jq -ce '
              if type == "array"
                and all(.[]; type == "array"
                  and length == 3
                  and all(.[]; type == "string" and length > 0))
              then unique
              else error("invalid notifier state")
              end
            ' "$state_file" 2>/dev/null
          )"; then
            printf 'firmware update notifier state is invalid\n' >&2
            exit 1
          fi

          new_release_count="$(
            jq -nr \
              --argjson current "$current_releases" \
              --argjson previous "$previous_releases" \
              '$current - $previous | length'
          )"

          if [ "$new_release_count" -gt 0 ]; then
            if ! "$notify_send" 'A firmware update is available.'; then
              printf 'firmware update notification failed\n' >&2
              exit 1
            fi
          fi

          write_state
        '';
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
