{ pkgs, emacs }:

pkgs.runCommand "emacs-literate-config" { nativeBuildInputs = [ emacs ]; } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  emacs --batch -Q --load ${../config/emacs/tangle.el} \
    --funcall my/emacs-tangle-batch ${../config/emacs/my-emacs.org} "$out"
''
