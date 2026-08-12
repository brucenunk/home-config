{ ... }:

{
  flake.modules.homeManager.git =
    { lib, pkgs, ... }:
    {
      home.packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.git-credential-manager ];

      programs.git = {
        enable = true;

        settings = {
          alias = {
            ci = "commit";
            co = "checkout";
            l = "lg -n 10";
            lg = "log --graph";
            st = "status";
            tags = ''for-each-ref --format="%(refname)" --sort=-taggerdate refs/tags'';
          };

          core = {
            editor = "emacsclient";
            fsmonitor = true;
            untrackedcache = true;
          };

          format.pretty = "%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset";
          init.defaultBranch = "main";
          push.autoSetupRemote = true;
          user.name = "James Lee";
        }
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          credential.helper = "${pkgs.git-credential-manager}/bin/git-credential-manager";
        };
      };
    };
}
