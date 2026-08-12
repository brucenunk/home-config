{ ... }:

{
  flake.modules.homeManager.golang =
    { pkgs, lib, ... }:

    {
      home.packages = with pkgs; [
        delve
        go-tools
        gofumpt
        golangci-lint
        golangci-lint-langserver
        golines
        (lib.hiPrio gopls)
        gotools
        kubebuilder
        kubernetes-controller-tools
        protobuf
        protoc-gen-go
        protoc-gen-go-grpc
      ];

      programs.go = {
        enable = true;
      };
    };
}
