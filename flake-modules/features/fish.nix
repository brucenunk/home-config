{ ... }:

{
  flake.modules.homeManager.fish =
    { pkgs, lib, ... }:

    let
      kubectlVerbAbbrs = {
        g = "get";
        e = "edit";
      };
      kubectlResourceAbbrs = {
        n = "namespaces";
        d = "deployments";
        p = "pods";
        s = "services";
        cm = "configmaps";
        sa = "serviceaccounts";
        r = "roles";
        rb = "rolebindings";
        cr = "clusterroles";
        crb = "clusterrolebindings";
        sts = "statefulsets";
      };
      kubectlShellAbbrs = lib.concatMapAttrs (
        verbAbbr: verb:
        {
          "k${verbAbbr}" = "kubectl ${verb}";
        }
        // lib.mapAttrs' (
          resourceAbbr: resource:
          lib.nameValuePair "k${verbAbbr}${resourceAbbr}" "kubectl ${verb} ${resource}"
        ) kubectlResourceAbbrs
      ) kubectlVerbAbbrs;
    in
    {
      programs.fish = {
        enable = true;

        shellInit = ''
          # fish 4.8 no longer imports the macOS login environment in the same way
          # fish 4.7 did. Keep the critical login paths explicit so Nix and Home
          # Manager tools remain available after a profile update.
          set -l login_paths \
            /Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home/bin \
            $HOME/.nix-profile/bin \
            /nix/var/nix/profiles/default/bin \
            /opt/homebrew/bin \
            /opt/homebrew/sbin

          for dir in $login_paths[-1..1]
            if test -d $dir; and not contains -- $dir $PATH
              set -gx PATH $dir $PATH
            end
          end
        '';

        interactiveShellInit = ''
          fish_config theme choose None

          for var in \
            fish_color_command \
            fish_color_comment \
            fish_color_end \
            fish_color_error \
            fish_color_escape \
            fish_color_keyword \
            fish_color_match \
            fish_color_operator \
            fish_color_option \
            fish_color_param \
            fish_color_quote \
            fish_color_redirection \
            fish_color_search_match \
            fish_color_selection \
            fish_color_valid_path \
            fish_pager_color_completion \
            fish_pager_color_description \
            fish_pager_color_prefix \
            fish_pager_color_progress \
            fish_pager_color_selected_completion \
            fish_pager_color_selected_description \
            fish_pager_color_selected_prefix
            set -g $var normal
          end

          set -g fish_color_autosuggestion brblack
          set -g fish_pager_color_selected_background --reverse

          set fish_greeting
          set -g fish_prompt_pwd_dir_length 0
        '';

        plugins = [
          {
            name = "fzf-fish";
            src = pkgs.fishPlugins.fzf-fish.src;
          }
        ];

        shellAbbrs = {
          "c" = "clear";
          "e" = "hx";
          "g" = "git";
          "k" = "kubectl";
          "kn" = "kubens";
          "l" = "ls";
        }
        // kubectlShellAbbrs;
      };
    };
}
