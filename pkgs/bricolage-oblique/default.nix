{
  lib,
  runCommand,
  python3,
  google-fonts,
}:

let
  upright = google-fonts.override { fonts = [ "Bricolage Grotesque" ]; };
in
runCommand "bricolage-grotesque-oblique"
  {
    nativeBuildInputs = [ (python3.withPackages (ps: [ ps.fonttools ])) ];
    meta = {
      description = "Mechanically slanted Bricolage Grotesque companion faces";
      license = lib.licenses.ofl;
      platforms = lib.platforms.all;
    };
  }
  ''
    python ${./generate.py} \
      '${upright}/share/fonts/truetype/BricolageGrotesque[opsz,wdth,wght].ttf' \
      "$out/share/fonts/truetype"
  ''
