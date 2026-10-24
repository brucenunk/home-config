{ pkgs }:

pkgs.stdenvNoCC.mkDerivation {
  pname = "excali-fonts";
  version = "2026-10-24";
  src = pkgs.fetchFromGitHub {
    owner = "excalidraw";
    repo = "excalidraw";
    rev = "b7de45e88111f5680ae4bb3c3f3541c7d3b279fe";
    hash = "sha256-65En0ZRLEuCixs4dh4ILNvIgMkwyLx6w05xXob27/RE=";
  };

  nativeBuildInputs = [
    pkgs.woff2
    pkgs.python3Packages.fonttools
    pkgs.fontconfig
  ];
  dontBuild = true;
  # Match upstream's make-fonts conversion, but with pinned, sandboxed inputs.
  # A single TTF per family avoids CoreText selecting just one WOFF2 subset.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    for family in Excalifont Nunito Lilita ComicShanns Liberation Cascadia Virgil; do
      mkdir -p "$out/$family"
      cp packages/excalidraw/fonts/"$family"/* "$out/$family/"
      files=("$out/$family/"*.woff2)
      for file in "''${files[@]}"; do
        woff2_decompress "$file"
        rm "$file"
      done
      ttfs=("$out/$family/"*.ttf)
      if (( ''${#ttfs[@]} > 1 )); then
        pyftmerge --output-file="$out/$family/$family-Regular.ttf" "''${ttfs[@]}"
        rm "''${ttfs[@]}"
      fi
    done
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export XDG_CACHE_HOME="$TMPDIR/fontconfig-cache"
    mkdir -p "$XDG_CACHE_HOME"
    for family in Excalifont Nunito Lilita ComicShanns Liberation Cascadia Virgil; do
      files=("$out/$family/"*.ttf)
      test "''${#files[@]}" -eq 1
      fc-scan --format '%{family}\n' "''${files[0]}" | grep -q .
    done
    runHook postInstallCheck
  '';

  meta = {
    description = "Excalidraw's seven bundled Latin font families for excali-mode";
    homepage = "https://github.com/excalidraw/excalidraw";
    license = [
      pkgs.lib.licenses.ofl
      pkgs.lib.licenses.mit
    ];
    platforms = pkgs.lib.platforms.all;
  };
}
