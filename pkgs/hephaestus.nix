{ pkgs, lib }:

let
  package = pkgs.rustPlatform.buildRustPackage {
    pname = "hephaestus";
    version = "0.1.0";
    src = lib.cleanSource ../rust/hephaestus;
    cargoLock.lockFile = ../rust/hephaestus/Cargo.lock;
    nativeCheckInputs = [ pkgs.git ];
    meta.mainProgram = "hephaestus";
  };
in
pkgs.symlinkJoin {
  name = "hephaestus";
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/hephaestus" \
      --prefix PATH : ${lib.makeBinPath [ pkgs.git ]}
  '';
}
