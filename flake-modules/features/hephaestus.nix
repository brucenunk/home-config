{ ... }:

{
  flake.modules.homeManager.hephaestus =
    { pkgs, lib, ... }:

    let
      hephaestus = import ../../pkgs/hephaestus.nix { inherit pkgs lib; };
    in
    {
      home.packages = [ hephaestus ];
    };
}
