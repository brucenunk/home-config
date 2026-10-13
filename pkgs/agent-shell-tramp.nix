{ epkgs, pkgs }:

epkgs.trivialBuild {
  pname = "agent-shell-tramp";
  version = "0.2.0";
  src = pkgs.fetchFromGitHub {
    owner = "junyi-hou";
    repo = "agent-shell-tramp";
    rev = "da17568f61c30133df1cf3fdf9d0fa4137cfd66e";
    hash = "sha256-J4TBVkhlaso+TQvFLBwnWqGu5q2eCW8978mYuD1BbqM=";
  };
  # Use the same pinned agent-shell and ACP dependencies as the main package.
  packageRequires = [ (import ./agent-shell.nix { inherit pkgs epkgs; }) ];
  postPatch = ''
    rm agent-shell-tramp-tests.el
  '';
  meta = {
    description = "TRAMP path mapping and local transcripts for agent-shell";
    homepage = "https://github.com/junyi-hou/agent-shell-tramp";
    license = pkgs.lib.licenses.gpl3Plus;
  };
}
