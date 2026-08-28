{ epkgs, pkgs }:

let
  ghostel = epkgs.ghostel;

  # Ghostel's nixpkgs package builds this module with Zig, whose dependency
  # fetcher is slow and unreliable. Keep the release metadata explicit so a
  # flake bump fails at evaluation time until the new assets are hash-pinned.
  supportedVersion = "0.49.0";
  modules = {
    "aarch64-darwin" = {
      asset = "ghostel-module-aarch64-macos.dylib";
      hash = "sha256-Brq06og1UVdtl4jIxCv9lzFPkBXWucIpQ0vgsuM0cWc=";
    };
    "x86_64-linux" = {
      asset = "ghostel-module-x86_64-linux.so";
      hash = "sha256-LXrO7M1ryhOv8cQ/KvHFO3+tLp1sFeygd10T3twcn+o=";
    };
  };

  system = pkgs.stdenv.hostPlatform.system;
  moduleSpec =
    if ghostel.version != supportedVersion then
      throw "Ghostel ${ghostel.version} has no hash-pinned prebuilt native modules"
    else if builtins.hasAttr system modules then
      modules.${system}
    else
      throw "Ghostel ${ghostel.version} has no hash-pinned prebuilt native module for ${system}";
  moduleExtension = pkgs.stdenv.hostPlatform.extensions.sharedLibrary;
  moduleAsset = pkgs.fetchurl {
    url = "https://github.com/dakra/ghostel/releases/download/v${ghostel.version}/${moduleSpec.asset}";
    inherit (moduleSpec) hash;
  };
  module = pkgs.runCommand "ghostel-module-${ghostel.version}" { } ''
    mkdir -p "$out"
    install --mode=444 ${moduleAsset} "$out/ghostel-module${moduleExtension}"
    printf '%s\n' '${ghostel.version}' > "$out/ghostel-module.version"
  '';
in
ghostel.overrideAttrs (old: {
  # Remove the source-built module's Zig dependencies from the package
  # derivation while retaining nixpkgs's expected module layout.
  zig = null;
  zigDeps = null;
  preBuild = ''
    install ${module}/ghostel-module${moduleExtension} ghostel-module${moduleExtension}
    install --mode=444 ${module}/ghostel-module.version ghostel-module.version
  '';
  passthru = {
    inherit module;
    inherit (old.passthru) updateScript;
  };
})
