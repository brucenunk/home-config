{ epkgs, ghostel }:

# Build the extension from the same release as the Ghostel it will load.
epkgs.trivialBuild {
  pname = "consult-ghostel";
  inherit (ghostel) version;
  src = "${ghostel.src}/extensions/consult-ghostel";
  packageRequires = [
    epkgs.consult
    ghostel
  ];
}
