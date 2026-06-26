{ lib, config, ... }:
let
  cfg = config.nixinate.images;
in
{
  options.nixinate.images = {
    raw = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable raw disk image output";
      };
      imageSize = lib.mkOption {
        type = lib.types.str;
        default = "20G";
        description = "Total raw disk image size";
      };
      espSize = lib.mkOption {
        type = lib.types.str;
        default = "1024M";
        description = "ESP partition size";
      };
      swapSize = lib.mkOption {
        type = lib.types.str;
        default = "8G";
        description = "Swap partition size";
      };
    };
    installer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable bootable installer image";
      };
    };
    qemu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable QEMU QCOW2 image";
      };
    };
    iso = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable ISO image";
      };
    };
  };

  # Import disko and apply default schema when raw images are enabled.
  # Users who define their own disko.devices override these defaults
  # via the NixOS module system (lib.mkDefault).
  config = lib.mkIf cfg.raw.enable {
    disko.devices.disk.main = lib.mkDefault {
      device = "/dev/null"; # overridden by image builder
      type = "disk";
      imageSize = cfg.raw.imageSize;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            type = "EF00";
            size = cfg.raw.espSize;
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          swap = {
            size = cfg.raw.swapSize;
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
  };
}
