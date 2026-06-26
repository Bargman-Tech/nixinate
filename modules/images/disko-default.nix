{ lib, config, ... }:
let
  cfg = config.nixinate.images.raw;
in
{
  # Only set defaults — user's own disko.devices overrides these
  disko.devices.disk.main = lib.mkDefault {
    device = "/dev/null"; # overridden by image builder
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = cfg.espSize;
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        swap = {
          size = cfg.swapSize;
          content = { type = "swap"; };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
