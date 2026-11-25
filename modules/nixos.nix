self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.claude-desktop;
  finalPackage =
    if cfg.cowork.enable then cfg.package.override { withCowork = true; } else cfg.package;
in
{
  options.programs.claude-desktop = {
    enable = lib.mkEnableOption "Claude Desktop";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage (self + "/pkgs/claude-desktop") { };
      defaultText = lib.literalExpression "pkgs.callPackage (claude-desktop-flake + \"/pkgs/claude-desktop\") { }";
      description = ''
        The Claude Desktop package. It is built against the system's nixpkgs,
        so `nixpkgs.config` must allow the unfree `claude-desktop` package.
      '';
    };

    cowork = {
      enable = lib.mkEnableOption ''
        Cowork, which runs tasks inside a local KVM virtual machine. Uses
        nixpkgs' qemu, OVMF and virtiofsd, and loads the vhost_vsock module'';

      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "alice" ];
        description = ''
          Users to add to the `kvm` group. NixOS makes /dev/kvm and
          /dev/vhost-vsock world-accessible by default, so this is only needed
          if your configuration restricts them to the `kvm` group.
        '';
      };
    };

    keyring.enable = lib.mkEnableOption ''
      GNOME Keyring as the Secret Service provider that stores the sign-in
      token. Not needed on GNOME or KDE Plasma, which already provide one'';
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ finalPackage ];

        # File chooser and, on Wayland, the GlobalShortcuts portal for Quick Entry.
        xdg.portal.enable = lib.mkDefault true;
        xdg.portal.extraPortals = lib.mkDefault [ pkgs.xdg-desktop-portal-gtk ];

        # D-Bus activation for the GNOME Shell search provider.
        services.dbus.packages = [ finalPackage ];
      }

      (lib.mkIf cfg.keyring.enable {
        services.gnome.gnome-keyring.enable = true;
      })

      (lib.mkIf cfg.cowork.enable {
        boot.kernelModules = [ "vhost_vsock" ];
        users.groups.kvm.members = cfg.cowork.users;
      })
    ]
  );
}
