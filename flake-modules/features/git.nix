{ ... }:

{
  flake.modules.homeManager.git =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.gh ];

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

          credential = {
            "https://gist.github.com".helper = [
              ""
              "!${pkgs.gh}/bin/gh auth git-credential"
            ];
            "https://github.com".helper = [
              ""
              "!${pkgs.gh}/bin/gh auth git-credential"
            ];
          };

          format.pretty = "%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset";
          init.defaultBranch = "main";
          push.autoSetupRemote = true;
          user.name = "James Lee";
        };
      };
    };
}
