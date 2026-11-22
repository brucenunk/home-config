{ epkgs, pkgs }:

let
  ghostel = epkgs.melpaStablePackages.ghostel;

  # Pair MELPA Stable's Lisp package with the same upstream release module.
  # TODO(bump-nix): Compare the MELPA Stable Ghostel version and src.rev from
  # Wampa's Emacs package set (before this override). If either changes, verify
  # the stable release tag matches src.rev and the loader layout still fits
  # postInstall. Prefetch both versioned release assets with nix store
  # prefetch-file, update the version and hashes, and check the Wampa build
  # uses the matching prebuilt module, not a Zig source build. Stop if the
  # release or assets don't match; don't fall back to a different version.
  supportedVersion = "0.66.0";
  modules = {
    "aarch64-darwin" = {
      asset = "ghostel-module-aarch64-macos.dylib";
      hash = "sha256-RrxsHRv+gaAlG73BOMYoKddYbcXj5bXD0PVI1SGuRgE=";
    };
    "x86_64-linux" = {
      asset = "ghostel-module-x86_64-linux.so";
      hash = "sha256-niPob03NXkE5ylWuS6iHLQTK2m4NFNUFCm4quUgMJ1Q=";
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
  # The loader looks for the native module and version sidecar in the
  # installed package's resource root. Leave the MELPA recipe unchanged.
  postInstall = (old.postInstall or "") + ''
    packageDir="$out/share/emacs/site-lisp/elpa/ghostel-${ghostel.melpaVersion}"
    test -f "$packageDir/ghostel.el"
    test -d "$packageDir/etc"
    ln -s ${module}/ghostel-module${moduleExtension} "$packageDir/ghostel-module${moduleExtension}"
    ln -s ${module}/ghostel-module.version "$packageDir/ghostel-module.version"
  '';
  passthru = (old.passthru or { }) // {
    inherit module;
  };
})
