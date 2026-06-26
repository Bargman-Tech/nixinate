# Image Generation — Implementation Action Plan

**Status:** Ready for execution
**Date:** 2026-06-26
**Branch:** `feat/image-generation`
**Scope:** Nixinate Phase 5 (MNGA) — Image and Installer Generation

---

## How This Plan Works

Each phase is broken into individual steps. Each step is a single task for
`bellana-deepseek`. After each phase, `tpol-minimax` verifies all work in
that phase before proceeding.

**Execution pattern:**
1. Give the step prompt to `bellana-deepseek`
2. Review the output
3. Commit the step with the specified commit message
4. After all steps in a phase are complete, give the verification prompt to `tpol-minimax`
5. If verification passes, tag the phase and move to the next
6. If verification fails, fix and re-verify before proceeding

**Commit convention:** Each step gets its own commit. Each phase gets a tag
on successful verification.

---

## Phase 1: Foundation

**Tag:** `v1.1.0-image-phase-1`
**Dependencies:** None

### Step 1.1: Add disko flake input

**Agent:** bellana-deepseek
**Files:** `flake.nix`, `flake.lock`

**Prompt:**
```
Add disko as a flake input to /speed-storage/repo/DarthPJB/nixinate/flake.nix.

1. Add to inputs:
   disko = {
     url = "github:nix-community/disko";
     inputs.nixpkgs.follows = "nixpkgs";
   };

2. Add disko to the outputs function parameters: { self, nixpkgs, disko, ... }:

3. Run: nix flake lock

Commit: "feat: add disko flake input for image generation"
```

**Verify:** `nix flake show` lists disko in inputs.

### Step 1.2: Add genImages skeleton to overlay

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Add a genImages library function and generateImages overlay entry to
/speed-storage/repo/DarthPJB/nixinate/flake.nix, parallel to the existing
genDeploy/generateApps.

1. In the outputs rec block, add after lib.genDeploy:
   lib.genImages = forAllSystems (system: pkgs: nixpkgsFor.${system}.generateImages);

2. In the overlay (overlays.default), inside the nixinate attrset, add after generateApps:
   generateImages = flake:
     let
       machines = builtins.attrNames flake.nixosConfigurations;
       validMachines = final.lib.remove "" (final.lib.forEach machines
         (x: final.lib.optionalString
           (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}"));
     in
       nixpkgs.lib.genAttrs validMachines (machine: {
         # Stub — filled in subsequent phases
       });

Commit: "feat: add genImages library function skeleton parallel to genDeploy"
```

**Verify:** `nix eval '.#lib.genImages'` returns a function.

### Step 1.3: Create image generation NixOS module options

**Agent:** bellana-deepseek
**Files:** `modules/images/default.nix` (new)

**Prompt:**
```
Create the image generation NixOS module at
/speed-storage/repo/DarthPJB/nixinate/modules/images/default.nix.

Create the directory modules/images/ first.

This module defines the nixinate.images option subtree:

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

Commit: "feat: add nixinate.images NixOS module options (raw/installer/qemu/iso)"
```

**Verify:** Module file exists and is valid Nix.

### Step 1.4: Create default disko schema module

**Agent:** bellana-deepseek
**Files:** `modules/images/disko-default.nix` (new)

**Prompt:**
```
Create the default disko schema module at
/speed-storage/repo/DarthPJB/nixinate/modules/images/disko-default.nix.

This provides the standard GPT layout when the user hasn't defined disko.devices:

Partition order: ESP (first, UEFI requirement) → swap → root ext4 (last, expandable)

{ lib, config, ... }:
with lib;
let
  cfg = config.nixinate.images.raw;
in
{
  disko.devices = mkIf (config.disko.devices == {}) {
    disk.main = {
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
  };
}

Commit: "feat: add default disko schema module (GPT: ESP → swap → root ext4)"
```

**Verify:** File exists, references cfg.espSize and cfg.swapSize correctly.

### Phase 1 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 1 (Foundation) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check the following:

1. Flake evaluates without errors:
   nix flake check --no-build

2. Disko input exists in flake.lock:
   nix flake metadata --json | jq '.locks.nodes | has("disko")'

3. genImages function exists:
   nix eval '.#lib.genImages'

4. Module options file exists and is valid Nix:
   cat modules/images/default.nix (verify structure)

5. Default disko schema file exists:
   cat modules/images/disko-default.nix (verify structure)

6. All changes are committed:
   git status (should be clean)

7. Git log shows the expected commits for this phase

Report: PASS or FAIL with specific details on any failures.
```

**On pass:** Tag `v1.1.0-image-phase-1` and proceed to Phase 2.
**On fail:** Identify specific failures, fix, re-verify.

---

## Phase 2: Raw Image Output

**Tag:** `v1.1.0-image-phase-2`
**Dependencies:** Phase 1 complete and tagged

### Step 2.1: Wire raw image building in generateImages

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Update the generateImages overlay function in
/speed-storage/repo/DarthPJB/nixinate/flake.nix to build actual raw disk images.

Replace the stub in generateImages with:

generateImages = flake:
  let
    machines = builtins.attrNames flake.nixosConfigurations;
    validMachines = final.lib.remove "" (final.lib.forEach machines
      (x: final.lib.optionalString
        (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}"));
    mkImagePackages = machine:
      let
        userConfig = flake.nixosConfigurations.${machine};
        imagesConfig = userConfig._module.args.nixinate.images or {};
        rawEnabled = imagesConfig.raw.enable or true;
        system = userConfig.config.nixpkgs.hostPlatform.system;

        rawDerivedConfig = if rawEnabled then
          (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              disko.nixosModules.disko
              ./modules/images/default.nix
              ./modules/images/disko-default.nix
              { _module.args.nixinate = userConfig._module.args.nixinate; }
            ];
          })
        else null;
      in
        (if rawEnabled then {
          "${machine}-raw-image" = rawDerivedConfig.config.system.build.diskoImages;
        } else {});
  in
    builtins.foldl' (a: b: a // b) {} (builtins.map mkImagePackages validMachines);

Commit: "feat: wire raw disk image building via disko in generateImages overlay"
```

**Verify:** `nix eval` shows the package attribute exists (build may not work yet without a test config).

### Step 2.2: Add zstd compression as derived package

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Add zstd-compressed raw image as a derived package in the generateImages overlay
in /speed-storage/repo/DarthPJB/nixinate/flake.nix.

After the raw-image entry in mkImagePackages, add:

raw-image-zstd = if rawEnabled then
  final.stdenv.mkDerivation {
    name = "${machine}-raw-image-zstd";
    buildInputs = [ final.zstd ];
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out
      zstd -3 -T0 -v -o $out/image.raw.zst \
        ${rawDerivedConfig.config.system.build.diskoImages}/installer.raw
    '';
  }
else null;

Level 3: 100x faster than level 19, <3% size difference.
-T0: parallel compression using all cores.

Commit: "feat: add zstd-compressed raw image derivation (level 3, parallel)"
```

**Verify:** The package attribute exists in the overlay output.

### Phase 2 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 2 (Raw Image Output) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check the following:

1. Flake evaluates:
   nix flake check --no-build

2. generateImages produces raw-image and raw-image-zstd attributes:
   nix eval --json '.#lib.genImages.x86_64-linux' 2>/dev/null || true
   (Check the structure has machine-raw-image keys)

3. The overlay's generateImages function references diskoImages:
   grep -n "diskoImages" flake.nix

4. The zstd derivation uses level 3 and -T0:
   grep -n "zstd -3 -T0" flake.nix

5. All changes committed:
   git status (clean)

Report: PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-2` and proceed to Phase 3.
**On fail:** Fix and re-verify.

---

## Phase 3: Installer Image

**Tag:** `v1.1.0-image-phase-3`
**Dependencies:** Phase 2 complete and tagged

### Step 3.1: Create installer NixOS module

**Agent:** bellana-deepseek
**Files:** `modules/images/installer.nix` (new)

**Prompt:**
```
Create the installer NixOS module at
/speed-storage/repo/DarthPJB/nixinate/modules/images/installer.nix.

This configures a minimal bootable system for the auto-installer.

Reference: /speed-storage/repo/SQUIRGLE_MEN/nix-workstation-image/machines/installer/default.nix

Keep it generic — no hardware-specific firmware, no branding.

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

Commit: "feat: add installer NixOS module (GRUB+EFI, ephemeral, minimal boot)"
```

**Verify:** File exists and is valid Nix.

### Step 3.2: Create auto-dd shell script

**Agent:** bellana-deepseek
**Files:** `modules/images/auto-dd-install.sh` (new)

**Prompt:**
```
Create the auto-dd-install shell script at
/speed-storage/repo/DarthPJB/nixinate/modules/images/auto-dd-install.sh.

Reference: /speed-storage/repo/SQUIRGLE_MEN/nix-workstation-image/shell/auto-dd-install.sh

Adapt to be generic:
- Remove all project-specific branding
- Target device: INSTALL_TARGET env var (default /dev/nvme0n1)
- Min disk size: INSTALL_MIN_DISK_GB env var (default 64)
- Image path: INSTALLER_IMAGE env var
- Keep all safety validations (target exists, not mounted, not current root, size check)
- Keep: zstd -d -c | dd of=$TARGET bs=4M status=progress conv=fsync
- Keep: sgdisk -e for GPT header relocation
- Keep: growpart + resize2fs for root expansion
- Keep: final layout display and shutdown message
- set -euo pipefail throughout
- Trap for cleanup on interruption

IMPORTANT: Swap is already in the disko schema (embedded in raw image).
Do NOT create swap post-dd. Only expand root.

Commit: "feat: add auto-dd-install shell script with safety validations"
```

**Verify:** `bash -n modules/images/auto-dd-install.sh` passes syntax check.

### Step 3.3: Create auto-dd systemd service module

**Agent:** bellana-deepseek
**Files:** `modules/images/auto-dd.nix` (new)

**Prompt:**
```
Create the auto-dd systemd service module at
/speed-storage/repo/DarthPJB/nixinate/modules/images/auto-dd.nix.

Reference: /speed-storage/repo/SQUIRGLE_MEN/nix-workstation-image/machines/installer-auto-dd/default.nix

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

Keep it generic. Use lib.mkDefault for settings users might override.

Commit: "feat: add auto-dd systemd service module with kmscon installer UX"
```

**Verify:** File exists, references auto-dd-install.sh correctly.

### Step 3.4: Wire installer image building in generateImages

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Add installer image building to the generateImages overlay in
/speed-storage/repo/DarthPJB/nixinate/flake.nix.

In mkImagePackages, add:

installerEnabled = imagesConfig.installer.enable or true;

installerDerivedConfig = if installerEnabled then
  (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      disko.nixosModules.disko
      ./modules/images/default.nix
      ./modules/images/installer.nix
      ./modules/images/auto-dd.nix
      { _module.args.nixinate = userConfig._module.args.nixinate; }
      { disko.devices.disk.autoinstaller = {
          device = "/dev/null";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                type = "EF00";
                size = "512M";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
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
          imageSize = "7800M";
        };
      }
    ];
  })
else null;

installer-image = if installerEnabled then
  final.runCommand "${machine}-installer-image" {
    nativeBuildInputs = [ final.coreutils ];
  } ''
    mkdir -p "$out"
    cp ${installerDerivedConfig.config.system.build.diskoImagesScript} ./disko-image-builder
    chmod +x ./disko-image-builder
    ./disko-image-builder \
      --post-format-files ${self.packages.${system}.${machine}-raw-image-zstd}/image.raw.zst install/image.raw.zst
    cp autoinstaller.raw "$out/installer.raw"
  ''
else null;

Add both to the returned attrset alongside raw-image and raw-image-zstd.

Commit: "feat: wire installer image building with diskoImagesScript --post-format-files"
```

**Verify:** The installer-image attribute exists in the overlay output.

### Phase 3 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 3 (Installer Image) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check the following:

1. Flake evaluates:
   nix flake check --no-build

2. Installer module exists and is valid:
   cat modules/images/installer.nix
   cat modules/images/auto-dd.nix
   cat modules/images/auto-dd-install.sh

3. Auto-dd script passes syntax check:
   bash -n modules/images/auto-dd-install.sh

4. generateImages references installer-image:
   grep -n "installer-image" flake.nix

5. diskoImagesScript is used for installer:
   grep -n "diskoImagesScript" flake.nix

6. --post-format-files is used to embed payload:
   grep -n "post-format-files" flake.nix

7. All changes committed:
   git status (clean)

Report: PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-3` and proceed to Phase 4.
**On fail:** Fix and re-verify.

---

## Phase 4: QEMU + ISO Outputs

**Tag:** `v1.1.0-image-phase-4`
**Dependencies:** Phase 2 complete and tagged

### Step 4.1: Add QEMU and ISO image outputs

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Add QEMU QCOW2 and ISO image outputs to the generateImages overlay in
/speed-storage/repo/DarthPJB/nixinate/flake.nix.

In mkImagePackages, add:

qemuEnabled = imagesConfig.qemu.enable or false;
isoEnabled = imagesConfig.iso.enable or false;

qemu-image = if qemuEnabled then
  (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      disko.nixosModules.disko
      ./modules/images/default.nix
      ./modules/images/disko-default.nix
      { _module.args.nixinate = userConfig._module.args.nixinate; }
      "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
    ];
  }).config.system.build.images.qemu
else null;

iso-image = if isoEnabled then
  (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      disko.nixosModules.disko
      ./modules/images/default.nix
      ./modules/images/disko-default.nix
      { _module.args.nixinate = userConfig._module.args.nixinate; }
      { virtualisation.virtualbox.guest.enable = true; }
    ];
  }).config.system.build.images.iso
else null;

Add both to the returned attrset. Defaults are false — user must explicitly enable.

Commit: "feat: add QEMU QCOW2 and ISO image outputs (images.qemu/iso.enable)"
```

**Verify:** Package attributes exist when enabled.

### Phase 4 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 4 (QEMU + ISO) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check the following:

1. Flake evaluates:
   nix flake check --no-build

2. QEMU output references images.qemu:
   grep -n "qemu-image" flake.nix

3. ISO output references images.iso:
   grep -n "iso-image" flake.nix

4. Both default to false:
   grep -n "qemu.enable or false" flake.nix
   grep -n "iso.enable or false" flake.nix

5. All changes committed:
   git status (clean)

Report: PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-4` and proceed to Phase 5.
**On fail:** Fix and re-verify.

---

## Phase 5: Closure Size Check

**Tag:** `v1.1.0-image-phase-5`
**Dependencies:** Phase 2 complete and tagged

### Step 5.1: Create closure size parsing helper

**Agent:** bellana-deepseek
**Files:** `lib/closure-size.nix` (new)

**Prompt:**
```
Create a closure size helper at
/speed-storage/repo/DarthPJB/nixinate/lib/closure-size.nix.

Create the lib/ directory if needed.

This helper parses imageSize/espSize/swapSize strings and computes available
root partition space:

{ lib, ... }:
let
  parseSize = str:
    let
      num = builtins.fromJSON (builtins.head (builtins.match "([0-9]+)" str));
      suffix = builtins.head (builtins.match "[0-9]+(.)" str);
    in
      num * (if suffix == "G" then 1024*1024*1024
        else if suffix == "M" then 1024*1024
        else if suffix == "K" then 1024
        else builtins.abort "Unknown size suffix: ${str}");
in
{
  # Export parseSize for use by other modules
  nixinate.lib.parseSize = parseSize;
}

Commit: "feat: add size parsing helper for image size calculations"
```

**Verify:** File exists, parseSize function is defined.

### Step 5.2: Wire closure size assertion into raw image build

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Add a closure size pre-flight check to the raw image build in
/speed-storage/repo/DarthPJB/nixinate/flake.nix.

In the generateImages overlay, before building the raw image, add a
build-time assertion that checks if the configured imageSize is reasonable.

The simplest approach for v1: add a warning derivation that runs before
the image build and checks closure size vs available root space.

In mkImagePackages, add:

# Size check
imageSizeBytes = (import ./lib/closure-size.nix { inherit lib; }).nixinate.lib.parseSize
  (imagesConfig.raw.imageSize or "20G");
espSizeBytes = (import ./lib/closure-size.nix { inherit lib; }).nixinate.lib.parseSize
  (imagesConfig.raw.espSize or "1024M");
swapSizeBytes = (import ./lib/closure-size.nix { inherit lib; }).nixinate.lib.parseSize
  (imagesConfig.raw.swapSize or "8G");
rootSizeBytes = imageSizeBytes - espSizeBytes - swapSizeBytes;

# Abort if root partition would be negative (bad config)
sizeValid = rootSizeBytes > 0;

Then wrap the raw-image output:
raw-image = if rawEnabled then
  (assert sizeValid; rawDerivedConfig.config.system.build.diskoImages)
else null;

This catches obviously bad sizing at eval time. A deeper closure-vs-image
check (comparing actual closure size) can be added in a future iteration.

Commit: "feat: add build-time image size validation before raw image build"
```

**Verify:** A config with imageSize smaller than espSize+swapSize fails at eval.

### Phase 5 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 5 (Closure Size Check) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check the following:

1. Flake evaluates:
   nix flake check --no-build

2. Size parsing helper exists:
   cat lib/closure-size.nix

3. parseSize function handles G, M, K suffixes:
   grep -n "suffix ==" lib/closure-size.nix

4. Size validation is wired into generateImages:
   grep -n "sizeValid" flake.nix
   grep -n "rootSizeBytes" flake.nix

5. All changes committed:
   git status (clean)

Report: PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-5` and proceed to Phase 6.
**On fail:** Fix and re-verify.

---

## Phase 6: Docs + Example

**Tag:** `v1.1.0-image-phase-6`
**Dependencies:** Phases 1-5 complete and tagged

### Step 6.1: Create example flake with image generation

**Agent:** bellana-deepseek
**Files:** `examples/flake-with-images.nix` (new)

**Prompt:**
```
Create an example flake at
/speed-storage/repo/DarthPJB/nixinate/examples/flake-with-images.nix
showing how to use image generation.

{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    nixinate = {
      url = "github:Bargman-Tech/nixinate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixinate, disko }: {
    # Deploy scripts
    apps = nixinate.lib.genDeploy.x86_64-linux self;

    # Image packages
    packages = nixinate.lib.genImages.x86_64-linux self;

    nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        disko.nixosModules.disko
        {
          _module.args.nixinate = {
            host = "10.0.0.1";
            sshUser = "deploy";
            images = {
              raw = {
                enable = true;
                imageSize = "20G";
                espSize = "1024M";
                swapSize = "8G";
              };
              installer.enable = true;
            };
          };
        }
      ];
    };
  };
}

Commit: "docs: add example flake with image generation configuration"
```

**Verify:** File exists, shows genImages and images config.

### Step 6.2: Update README with image generation section

**Agent:** bellana-deepseek
**Files:** `README.md`

**Prompt:**
```
Add an Image Generation section to
/speed-storage/repo/DarthPJB/nixinate/README.md.

Add after the existing deployment documentation, before Troubleshooting:

## Image Generation

Nixinate can generate disk images and bootable installers from your
nixosConfiguration. Add to your flake:

```nix
packages = nixinate.lib.genImages.x86_64-linux self;
```

### Available Outputs

| Output | Command | Description |
|--------|---------|-------------|
| Raw image | `nix build .#<machine>-raw-image` | dd-able disk image |
| Compressed | `nix build .#<machine>-raw-image-zstd` | zstd-compressed (level 3) |
| Installer | `nix build .#<machine>-installer-image` | Bootable USB installer |
| QEMU | `nix build .#<machine>-qemu-image` | QCOW2 (requires qemu profile) |
| ISO | `nix build .#<machine>-iso-image` | Bootable ISO (requires virtualbox) |

### Configuration

```nix
_module.args.nixinate.images = {
  raw = {
    enable = true;         # default: true
    imageSize = "20G";     # default: 20G
    espSize = "1024M";     # default: 1024M
    swapSize = "8G";       # default: 8G
  };
  installer.enable = true; # default: true
  qemu.enable = false;     # default: false
  iso.enable = false;      # default: false
};
```

See [`docs/image-generation-plan.md`](docs/image-generation-plan.md) for
the full architecture and implementation details.

Commit: "docs: add image generation section to README"
```

**Verify:** README contains the new section.

### Phase 6 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 6 (Docs + Example) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check the following:

1. Example flake exists:
   cat examples/flake-with-images.nix

2. Example shows genImages usage:
   grep -n "genImages" examples/flake-with-images.nix

3. Example shows images config:
   grep -n "images" examples/flake-with-images.nix

4. README has image generation section:
   grep -n "Image Generation" README.md

5. README shows package commands:
   grep -n "raw-image" README.md

6. All changes committed:
   git status (clean)

7. Plan document exists:
   cat docs/image-generation-plan.md | head -5

Report: PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-6`. All phases complete.
**On fail:** Fix and re-verify.

---

## Summary

| Phase | Tag | Steps | Agent | Gate |
|-------|-----|-------|-------|------|
| 1. Foundation | `v1.1.0-image-phase-1` | 4 | bellana-deepseek | tpol-minimax |
| 2. Raw Image | `v1.1.0-image-phase-2` | 2 | bellana-deepseek | tpol-minimax |
| 3. Installer | `v1.1.0-image-phase-3` | 4 | bellana-deepseek | tpol-minimax |
| 4. QEMU + ISO | `v1.1.0-image-phase-4` | 1 | bellana-deepseek | tpol-minimax |
| 5. Closure Check | `v1.1.0-image-phase-5` | 2 | bellana-deepseek | tpol-minimax |
| 6. Docs + Example | `v1.1.0-image-phase-6` | 2 | bellana-deepseek | tpol-minimax |

**Total:** 16 steps, 6 verification gates, 6 tags.
