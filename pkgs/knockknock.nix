{ epkgs, pkgs }:

epkgs.trivialBuild {
  pname = "knockknock";
  version = "0.3.0";
  src = pkgs.fetchFromGitHub {
    owner = "konrad1977";
    repo = "knockknock";
    rev = "0920b9b390d4b4cc0818574e115d87eb245a41b5";
    hash = "sha256-hTkXfXMIEL4GtZV177/6uFybdmH+zxwsDnaXSXvG4hs=";
  };
  packageRequires = [
    epkgs.posframe
    epkgs.nerd-icons
  ];
  meta.license = pkgs.lib.licenses.mit;
}
