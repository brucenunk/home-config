{ ... }:

{
  flake.modules.homeManager.kube =
    { pkgs, lib, ... }:

    {
      home.packages =
        with pkgs;
        [
          clusterctl
          kind
          kubectl
          kubectx
          kubernetes-helm
          kustomize_4

          # Provides envsubst.
          gettext

          # Useful for controller development and cluster operations.
          kubebuilder
          kubernetes-controller-tools
          stern

          cilium-cli
          cmctl
          hubble
        ]
        ++ lib.optionals pkgs.stdenv.isLinux [
          nerdctl
        ];
    };
}
