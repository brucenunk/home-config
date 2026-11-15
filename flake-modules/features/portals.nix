{ ... }:

{
  flake.modules.homeManager.portals =
    { ... }:

    {
      # NixOS supplies the portal service and backends. Darkman updates the
      # shared colour preference; GTK publishes it alongside font settings.
      xdg.configFile."xdg-desktop-portal/niri-portals.conf".text = ''
        [preferred]
        default=gnome;gtk;
        org.freedesktop.impl.portal.Access=gtk;
        org.freedesktop.impl.portal.Notification=gtk;
        org.freedesktop.impl.portal.Secret=gnome-keyring;
        org.freedesktop.impl.portal.Settings=gtk;
      '';
    };
}
