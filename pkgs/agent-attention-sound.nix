{ pkgs }:

pkgs.runCommand "agent-attention.wav" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python ${../config/emacs/sounds/generate-attention.py} "$out"
  python ${../config/emacs/sounds/generate-attention.py} second.wav
  cmp "$out" second.wav
  echo '5747f10394a6cd83d644362647901417ff771ba389556298058576f296cf08db  second.wav' | sha256sum --check
''
