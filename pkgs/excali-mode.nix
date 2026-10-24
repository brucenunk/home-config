{ pkgs, emacs }:

pkgs.stdenv.mkDerivation {
  pname = "excali-mode";
  version = "0.3.0";

  src = pkgs.fetchFromGitHub {
    owner = "yibie";
    repo = "excali-mode";
    rev = "bf92e954f82b5799ae46ceea1bbe1457824abf12";
    hash = "sha256-sJY+hPzXN++BF/cNNRxp7fveBQBOWyfH9myK6E4Ne60=";
  };

  nativeBuildInputs = [
    emacs
    pkgs.pkg-config
  ];
  buildInputs = with pkgs; [
    cairo
    pango
    zlib
    fontconfig
    librsvg
    gdk-pixbuf
    libwebp
  ];
  makeFlags = [ "EMACS_MODULE_INCLUDE=${emacs}/include" ];
  preBuild = ''
    ${emacs}/bin/emacs --batch -Q --eval '
      (unless (and (>= emacs-major-version 32)
                   (fboundp (quote module-load))
                   (fboundp (quote canvas-refresh))
                   (memq (quote canvas) image-types))
        (error "excali-mode requires graphical Emacs 32+ with modules and Canvas support"))'
  '';
  # Upstream's fixed /tmp output collides across Nix build users/runs.
  postPatch = ''
    substituteInPlace test/excali-board-reading-test.el \
      --replace-fail '"/tmp/excali-reading-verified.png"' \
      '(expand-file-name "excali-reading-verified.png" temporary-file-directory)'
  '';
  enableParallelBuilding = true;
  doCheck = true;
  checkTarget = "test";

  installPhase = ''
    runHook preInstall
    dest="$out/share/emacs/site-lisp/excali"
    mkdir -p "$dest"
    cp excali*.el ob-excali.el *.elc excali-module.* "$dest/"
    cp -R fonts "$dest/"
    cp -R ${import ./excali-fonts.nix { inherit pkgs; }}/* "$dest/fonts/"
    runHook postInstall
  '';

  meta = {
    description = "Native Excalidraw editor for Emacs with Canvas support";
    homepage = "https://github.com/yibie/excali-mode";
    license = pkgs.lib.licenses.gpl3Plus;
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };
}
