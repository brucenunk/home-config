{ epkgs, pkgs }:

epkgs.trivialBuild {
  pname = "agent-shell-notifications";
  version = "0.1.0";
  src = pkgs.fetchFromGitHub {
    owner = "zackattackz";
    repo = "agent-shell-notifications";
    rev = "fbf7a6b8c16326242d6e07430b7a8f5e84442466";
    hash = "sha256-aSEq4VHIcQVY6AEhqEtOR1FcxAvV2rDdgcFh/C0vhBk=";
  };
  packageRequires = [
    (import ./agent-shell.nix { inherit pkgs epkgs; })
  ];
  # The optional backend requires KnockKnock during byte compilation.  Do not
  # ship it: our provider is audio-only and needs only the notification core.
  postPatch = ''
    rm agent-shell-notifications-knockknock.el
  '';
  meta.license = pkgs.lib.licenses.gpl3Plus;
}
