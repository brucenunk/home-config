{
  lib,
  runCommand,
  python3,
  google-fonts,
  fontconfig,
}:

let
  upright = google-fonts.override { fonts = [ "Bricolage Grotesque" ]; };
in
runCommand "bricolage-grotesque-static"
  {
    nativeBuildInputs = [
      (python3.withPackages (ps: [ ps.fonttools ]))
      fontconfig
    ];
    meta = {
      description = "Matched static upright and mechanically slanted Bricolage Grotesque faces";
      license = lib.licenses.ofl;
      platforms = lib.platforms.all;
    };
  }
  ''
    python ${./generate.py} \
      '${upright}/share/fonts/truetype/BricolageGrotesque[opsz,wdth,wght].ttf' \
      "$out/share/fonts/truetype"

    export FONTCONFIG_FILE="$TMPDIR/fonts.conf"
    cat > "$FONTCONFIG_FILE" <<EOF
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>$out/share/fonts/truetype</dir>
      <cachedir>$TMPDIR/font-cache</cachedir>
    </fontconfig>
    EOF
    # Exercise actual matching, not just metadata: static italic faces used to
    # win even explicit roman requests when the upright peers were variable.
    for entry in 40:ExtraLight 50:Light 80:Regular 100:Medium 180:SemiBold 200:Bold 205:ExtraBold; do
      weight=''${entry%%:*}
      label=''${entry#*:}
      for slant in 0 100; do
        suffix=""
        if [ "$slant" = 100 ]; then suffix=Italic; fi
        actual=$(fc-match --format '%{file}|%{slant}' "Bricolage Grotesque:weight=$weight:slant=$slant")
        expected="$out/share/fonts/truetype/BricolageGrotesque-$label$suffix.ttf|$slant"
        if [ "$actual" != "$expected" ]; then
          echo "Font match mismatch: expected $expected, got $actual" >&2
          exit 1
        fi
      done
    done
  ''
