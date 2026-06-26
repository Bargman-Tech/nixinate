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
}
