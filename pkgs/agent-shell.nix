{ epkgs, pkgs }:

let
  # The pinned agent-shell needs newer dependencies than nixpkgs provides.
  acp = epkgs.acp.overrideAttrs (_old: {
    version = "0.17.1";
    commit = "v0.17.1";
    src = pkgs.fetchFromGitHub {
      owner = "xenodium";
      repo = "acp.el";
      rev = "v0.17.1";
      hash = "sha256-vRvUAP3Al7itI6iaqUaRXNifYp4vfGvbSATfUYCrHHg=";
    };
  });
  shell-maker = epkgs.shell-maker.overrideAttrs (_old: {
    version = "0.97.5";
    commit = "v0.97.5";
    src = pkgs.fetchFromGitHub {
      owner = "xenodium";
      repo = "shell-maker";
      rev = "v0.97.5";
      hash = "sha256-8ObWd2bo6f71MzYqiVJ8Cz2NRmvpgfr1gQ/b8Sr9uzU=";
    };
  });
in
(epkgs.agent-shell.override { inherit acp shell-maker; }).overrideAttrs (_old: {
  commit = "956a0be6b56e21b6de47a74a2a52fed0288b2abb";
  src = pkgs.fetchFromGitHub {
    owner = "xenodium";
    repo = "agent-shell";
    rev = "956a0be6b56e21b6de47a74a2a52fed0288b2abb";
    hash = "sha256-R9t+1VwCnHFFxeEJp/WRfzect5pehiumFSH1i836lGI=";
  };
  version = "20261013.250";
})
