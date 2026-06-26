{ config, lib, pkgs, ... }:
{
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
    timeoutStyle = lib.mkForce "menu";
  };
  boot.loader.efi = {
    canTouchEfiVariables = false;
    efiSysMountPoint = "/boot";
  };
  boot.kernelParams = [ "console=tty0" "boot.shell_on_fail" "loglevel=7" ];
  boot.plymouth.enable = lib.mkDefault true;

  hardware.graphics.enable = lib.mkForce false;
  hardware.enableAllHardware = lib.mkForce false;
  hardware.enableRedistributableFirmware = lib.mkForce false;

  fileSystems."/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "size=4G" "mode=1777" ];
  };
  systemd.tmpfiles.rules = [ "d /tmp/home 0755 root root -" ];
  nixpkgs.config.allowUnfree = true;
}
