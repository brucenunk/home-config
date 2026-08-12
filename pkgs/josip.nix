{ pkgs }:

let
  infoPlist = pkgs.writeText "Josip-Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key>
          <string>Josip</string>
          <key>CFBundleDisplayName</key>
          <string>Josip</string>
          <key>CFBundleIdentifier</key>
          <string>works.brucenunk.josip</string>
          <key>CFBundleExecutable</key>
          <string>Josip</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>LSUIElement</key>
          <true/>
          <key>NSMicrophoneUsageDescription</key>
          <string>Josip records microphone audio only after you explicitly start dictation.</string>
        </dict>
        </plist>
  '';

  launcher = pkgs.writeShellScript "josip" ''
    set -euo pipefail
    usage='usage: josip --output <output.wav> --max-duration <seconds> --stop-file <path> --ready-file <path>'
    original_args=("$@")
    output=""
    duration=""
    stop_file=""
    ready_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output)
          [ "$#" -ge 2 ] || { echo "missing value for --output" >&2; echo "$usage" >&2; exit 64; }
          output="$2"
          shift 2
          ;;
        --max-duration)
          [ "$#" -ge 2 ] || { echo "missing value for --max-duration" >&2; echo "$usage" >&2; exit 64; }
          duration="$2"
          shift 2
          ;;
        --stop-file)
          [ "$#" -ge 2 ] || { echo "missing value for --stop-file" >&2; echo "$usage" >&2; exit 64; }
          stop_file="$2"
          shift 2
          ;;
        --ready-file)
          [ "$#" -ge 2 ] || { echo "missing value for --ready-file" >&2; echo "$usage" >&2; exit 64; }
          ready_file="$2"
          shift 2
          ;;
        --help|-h)
          echo "$usage"
          exit 0
          ;;
        *)
          echo "unknown option: $1" >&2
          echo "$usage" >&2
          exit 64
          ;;
      esac
    done
    if [ -z "$output" ] || [ -z "$duration" ] || [ -z "$stop_file" ] || [ -z "$ready_file" ]; then
      echo "$usage" >&2
      exit 64
    fi
    if ! awk 'BEGIN { exit !(ARGV[1] > 0 && ARGV[1] <= 90) }' "$duration"; then
      echo "--max-duration must be greater than 0 and no more than 90" >&2
      exit 64
    fi
    /usr/bin/open -W -n -g "@app@" --args "''${original_args[@]}"
    status="$?"
    if [ "$status" -ne 0 ]; then
      exit "$status"
    fi
    if [ ! -s "$output" ]; then
      echo "Josip did not create an audio file. Check microphone permission for Josip." >&2
      exit 1
    fi
  '';
in
pkgs.runCommandLocal "josip" { } ''
  app="$out/Applications/Josip.app"
  mkdir -p "$app/Contents/MacOS" "$out/bin"

  ${pkgs.swift}/bin/swiftc ${../swift/josip/Josip.swift} \
    -framework AVFoundation \
    -framework Foundation \
    -o "$app/Contents/MacOS/Josip"

  cp ${infoPlist} "$app/Contents/Info.plist"
  /usr/bin/codesign --force --sign - "$app"

  cp ${launcher} "$out/bin/josip"
  substituteInPlace "$out/bin/josip" --replace-fail @app@ "$app"
  chmod +x "$out/bin/josip"
''
