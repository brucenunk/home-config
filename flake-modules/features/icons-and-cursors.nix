{ ... }:

{
  flake.modules.homeManager.icons-and-cursors =
    { pkgs, ... }:

    {
      gtk = {
        enable = true;
        iconTheme = {
          package = pkgs.adwaita-icon-theme;
          name = "Adwaita";
        };
      };

      home.pointerCursor = {
        enable = true;
        package = pkgs.phinger-cursors;
        name = "phinger-cursors-light";
        size = 24;
        gtk.enable = true;
        x11.enable = true;
      };
    };
}
