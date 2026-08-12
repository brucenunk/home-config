{ ... }:

{
  flake.modules.homeManager.bazel =
    { pkgs, ... }:

    {
      home = {
        file.".bazelrc".text = ''
          run --ui_event_filters=-info
          run --noshow_progress
        '';
        packages = with pkgs; [
          bazel-buildtools
          bazel-gazelle
          bazelisk
          (writeShellScriptBin "bazel" "${bazelisk}/bin/bazelisk \"$@\"")

          starlark
        ];
      };
    };
}
