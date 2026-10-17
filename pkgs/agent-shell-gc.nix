{ epkgs, pkgs }:

epkgs.trivialBuild {
  pname = "agent-shell-gc";
  version = "0.1.0";
  src = pkgs.fetchFromGitHub {
    owner = "izeigerman";
    repo = "agent-shell-gc";
    rev = "e3b5e1d62187bc7dd3b1d34bdfe7b571ffb1efae";
    hash = "sha256-aALFT1RTbLhIjpENfrcSpbtXaYSqJ2+mO8QkIJA9E04=";
  };
  # nixpkgs has no agent-shell-gc package; share our pinned agent-shell.
  packageRequires = [ (import ./agent-shell.nix { inherit pkgs epkgs; }) ];
  meta = {
    description = "Garbage collection for agent-shell sessions and worktrees";
    homepage = "https://github.com/izeigerman/agent-shell-gc";
    license = pkgs.lib.licenses.mit;
  };
}
