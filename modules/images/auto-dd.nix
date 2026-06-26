{ config, lib, pkgs, ... }:
let
  auto-dd-install = pkgs.writeShellApplication {
    name = "auto-dd-install";
    text = ''
      export INSTALLER_IMAGE="/install/image.raw.zst"
      ${builtins.readFile ./auto-dd-install.sh}
    '';
    runtimeInputs = with pkgs; [
      util-linux cloud-utils parted e2fsprogs zstd coreutils
      gptfdisk gawk gnugrep gnused findutils systemd
    ];
  };
in
{
  services.kmscon = {
    enable = lib.mkDefault true;
    hwRender = true;
    extraOptions = lib.escapeShellArgs [
      "--login" "--"
      "${pkgs.bash}/bin/bash" "-lc"
      "exec ${pkgs.systemd}/bin/journalctl -b -u auto-dd-install -f -o cat"
    ];
  };

  systemd.services.auto-dd-install = {
    description = "Nixinate Auto-Installer (dd-based)";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${auto-dd-install}/bin/auto-dd-install";
    };
  };
}
