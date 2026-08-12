{ ... }:

{
  flake.modules.homeManager.emacs =
    { pkgs, ... }:

    let
      # Keep Darwin on stock pkgs.emacs so it can use nixpkgs cache substitutes.
      # Adding overrideAttrs here creates a custom derivation and can force slow
      # local Emacs rebuilds during flake bumps.
      package = if pkgs.stdenv.isLinux then pkgs.emacs-pgtk else pkgs.emacs;

      # Nix owns Emacs package and Tree-sitter parser installation; use-package
      # owns package configuration in config/emacs.
      emacsPackages =
        epkgs: with epkgs; [
          auto-dark
          avy
          bazel
          consult
          consult-denote
          corfu
          denote
          doric-themes
          editorconfig
          embark
          embark-consult
          envrc
          exec-path-from-shell
          fontaine
          forge
          ghostel
          jsonnet-mode
          lin
          magit
          marginalia
          markdown-mode
          mixed-pitch
          nix-ts-mode
          orderless
          pulsar
          rainbow-delimiters
          rego-mode
          spacious-padding
          terraform-mode
          vertico
          wgrep
          ws-butler
          yaml-mode
        ];

      # Keep this curated list aligned with configured languages in
      # config/emacs/init.el rather than installing every grammar from nixpkgs.
      treeSitterGrammars =
        grammars: with grammars; [
          tree-sitter-bash
          tree-sitter-dockerfile
          tree-sitter-go
          tree-sitter-gomod
          tree-sitter-gotmpl
          tree-sitter-gowork
          tree-sitter-hcl
          tree-sitter-json
          tree-sitter-jsonnet
          tree-sitter-markdown
          tree-sitter-markdown-inline
          tree-sitter-nix
          tree-sitter-python
          # Starlark/Bazel would belong here too, but this nixpkgs revision does
          # not expose a tree-sitter-starlark grammar in tree-sitter.builtGrammars.
          tree-sitter-rego
          tree-sitter-yaml
        ];
    in
    {
      programs.emacs = {
        enable = true;

        extraPackages =
          epkgs: emacsPackages epkgs ++ [ (epkgs.treesit-grammars.with-grammars treeSitterGrammars) ];

        package = package;
      };

      home.sessionVariables = {
        EDITOR = "emacsclient";
        VISUAL = "emacsclient";
      };

      xdg.configFile."emacs/early-init.el".source = ../../config/emacs/early-init.el;
      xdg.configFile."emacs/init.el".source = ../../config/emacs/init.el;
      xdg.configFile."emacs/my-lisp".source = ../../config/emacs/my-lisp;
      xdg.configFile."emacs/my-emacs-modules".source = ../../config/emacs/my-emacs-modules;
    };
}
