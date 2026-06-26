# Image Generation — Implementation Action Plan

**Status:** Revised (post-adversarial review)
**Date:** 2026-06-26
**Branch:** `feat/image-generation`
**Scope:** Nixinate Phase 5 (MNGA) — Image and Installer Generation

---

## How This Plan Works

Each phase is broken into individual steps. Each step is a single task for
`bellana-deepseek`. After each phase, `tpol-minimax` verifies all work.

**Execution pattern:**
1. Give the step prompt to `bellana-deepseek`
2. Review the output
3. Commit the step with the specified commit message
4. After all steps in a phase, give the verification prompt to `tpol-minimax`
5. If verification passes, tag the phase and proceed
6. If verification fails, fix and re-verify

**Commit convention:** Each step gets its own commit. Each phase gets a tag.

---

## Core Architecture Decision

**Raw images read from the user's existing `nixosConfiguration`.**
The existing `generateApps` reads `flake.nixosConfigurations.${machine}._module.args.nixinate`
and generates deployment scripts. `generateImages` follows the same pattern — it reads
`config.system.build.diskoImages` from the user's already-evaluated config.

The user imports `nixinate.nixosModules.image-gen` (which adds disko + default schema)
into their own `nixosConfiguration`. No derived `nixosSystem` is needed for raw images.

**The installer is a separate `nixosSystem`.** The installer is a genuinely different
system — minimal boot shell, auto-dd service, embedded payload. It does NOT include
the user's desktop/apps/auth. It only needs the disko schema for its own disk layout
and the compressed raw image as a payload.

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

The existing pattern is:
  lib.genDeploy = forAllSystems (system: pkgs: nixpkgsFor.${system}.generateApps);

Follow this EXACTLY for genImages:
  lib.genImages = forAllSystems (system: pkgs: nixpkgsFor.${system}.generateImages);

In the overlay (overlays.default), add generateImages INSIDE the nixinate
attrset, parallel to generateApps:

  generateImages = flake:
    let
      machines = builtins.attrNames flake.nixosConfigurations;
      validMachines = final.lib.filter (x: x != "")
        (final.lib.forEach machines (x:
          final.lib.optionalString
            (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}"));
    in
      final.lib.genAttrs validMachines (machine: {
        # Stub — filled in subsequent phases
      });

NOTE: Use final.lib.filter + final.lib.forEach (NOT lib.remove which doesn't exist).
The stub returns an empty attrset per machine for now.

Commit: "feat: add genImages library function skeleton parallel to genDeploy"
```

**Verify:** `nix eval '.#lib.genImages'` returns a function.

### Step 1.3: Create image generation NixOS module

**Agent:** bellana-deepseek
**Files:** `modules/images/default.nix` (new)

**Prompt:**
```
Create the image generation NixOS module at
/speed-storage/repo/DarthPJB/nixinate/modules/images/default.nix.

Create the directory modules/images/ first.

This module:
1. Defines nixinate.images options (read by generateImages via _module.args)
2. When raw images are enabled, imports disko and applies default schema
3. Bridges _module.args.nixinate.images to config.nixinate.images

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

This provides the standard GPT layout when the user hasn't defined their own
disko.devices.disk entries. It only applies defaults — the user's config
takes precedence via NixOS module system (lib.mkDefault).

Partition order: ESP (first, UEFI requirement) → swap → root ext4 (last, expandable)

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

NOTE: Uses lib.mkDefault on the entire disk attrset, not mkIf on config.disko.devices.
This means if the user defines their own disko.devices.disk.main, it overrides
the default cleanly via the module system. No brittle == {} checks.

Commit: "feat: add default disko schema module (GPT: ESP → swap → root ext4)"
```

**Verify:** File exists, uses lib.mkDefault correctly.

### Phase 1 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 1 (Foundation) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check:
1. nix flake check --no-build (flake evaluates)
2. nix flake metadata --json | jq '.locks.nodes | has("disko")' (disko input exists)
3. nix eval '.#lib.genImages' (function exists)
4. cat modules/images/default.nix (options defined, valid Nix)
5. cat modules/images/disko-default.nix (uses lib.mkDefault, valid Nix)
6. git status (clean, all committed)

Report PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-1`.
**On fail:** Fix and re-verify.

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
/speed-storage/repo/DarthPJB/nixinate/flake.nix to build raw disk images.

KEY ARCHITECTURE: Raw images read from the user's EXISTING nixosConfiguration.
Do NOT create a new nixpkgs.lib.nixosSystem. The user's config already has
disko imported (via nixinate.nixosModules.image-gen) and disko.devices defined
(either their own or the nixinate default).

Follow the same pattern as generateApps — read from flake.nixosConfigurations:

generateImages = flake:
  let
    machines = builtins.attrNames flake.nixosConfigurations;
    validMachines = final.lib.filter (x: x != "")
      (final.lib.forEach machines (x:
        final.lib.optionalString
          (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}"));
    mkImagePackages = machine:
      let
        userConfig = flake.nixosConfigurations.${machine};
        imagesConfig = userConfig._module.args.nixinate.images or {};
        rawEnabled = imagesConfig.raw.enable or true;
        system = userConfig.config.nixpkgs.hostPlatform.system;
      in
        (if rawEnabled then {
          "${machine}-raw-image" = userConfig.config.system.build.diskoImages;
        } else {});
  in
    builtins.foldl' (a: b: a // b) {} (builtins.map mkImagePackages validMachines);

The user's config MUST import nixinate.nixosModules.image-gen for disko
to be available. This is the user's responsibility — same as importing
any other NixOS module.

Commit: "feat: wire raw disk image reading from user's nixosConfiguration"
```

**Verify:** `nix eval` shows the package attribute exists.

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
        ${userConfig.config.system.build.diskoImages}/installer.raw
    '';
  }
else null;

This references userConfig directly — no derived config, no self.packages.
Level 3: 100x faster than level 19, <3% size difference.
-T0: parallel compression using all cores.

NOTE: The output filename (installer.raw) depends on the disko disk key name.
If the user defines disko.devices.disk.main, the output will be main.raw.
If they define disko.devices.disk.installer, it will be installer.raw.
The default schema uses "main", so the default output is main.raw.

Adjust the path accordingly — check what disko actually outputs for the
default schema.

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

Check:
1. nix flake check --no-build (flake evaluates)
2. grep -n "raw-image" flake.nix (raw image referenced)
3. grep -n "raw-image-zstd" flake.nix (zstd variant referenced)
4. grep -n "diskoImages" flake.nix (reads from user's config)
5. grep -n "zstd -3 -T0" flake.nix (correct compression settings)
6. grep -n "userConfig.config.system.build" flake.nix (reads from existing config, NOT new nixosSystem)
7. git status (clean)

Report PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-2`.
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
It does NOT include the user's desktop/apps/auth — it's a separate, minimal system.

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

The script runs on every boot — this is the intended behavior. The user
removes the USB after installation completes and the system shuts down.
If the USB is left in, the installer runs again (also intended).

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

Use pkgs.writeShellApplication (NOT writeShellScriptBin) per prime directive 18.

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

NOTE: The service runs on every boot (wantedBy multi-user.target). This is
the intended behavior — the user removes the USB after installation.

Commit: "feat: add auto-dd systemd service module with kmscon installer UX"
```

**Verify:** File exists, uses writeShellApplication.

### Step 3.4: Wire installer image building in generateImages

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Add installer image building to the generateImages overlay in
/speed-storage/repo/DarthPJB/nixinate/flake.nix.

The installer IS a separate nixosSystem — it's a different system entirely
(minimal boot shell + auto-dd, not the user's desktop). Create it using
nixpkgs.lib.nixosSystem with the installer modules.

In mkImagePackages, add:

installerEnabled = imagesConfig.installer.enable or true;

# Installer is a SEPARATE system — not the user's config
installerDerivedConfig = if installerEnabled then
  (final.lib.nixosSystem {
    inherit system;
    modules = [
      disko.nixosModules.disko
      ./modules/images/default.nix
      ./modules/images/installer.nix
      ./modules/images/auto-dd.nix
      # Minimal disko schema for the installer USB itself
      {
        disko.devices.disk.autoinstaller = {
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
        };
        disko.devices.disk.autoinstaller.imageSize = "7800M";
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

NOTE: Uses final.lib.nixosSystem (not nixpkgs.lib.nixosSystem) because
nixpkgs is not in scope inside the overlay. final.lib has nixosSystem.

The installer uses its own disk key ("autoinstaller") to avoid collision
with the user's disk key ("main" or whatever they defined).

The zstd payload is referenced via self.packages — this is safe because
the installer-image depends on raw-image-zstd which is built in the same
generateImages call. The dependency is explicit.

Add installer-image to the returned attrset alongside raw-image and raw-image-zstd.

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

Check:
1. nix flake check --no-build (flake evaluates)
2. cat modules/images/installer.nix (valid Nix, has efiInstallAsRemovable)
3. cat modules/images/auto-dd.nix (uses writeShellApplication, has runtimeInputs)
4. cat modules/images/auto-dd-install.sh (bash -n passes)
5. grep -n "installer-image" flake.nix (installer output wired)
6. grep -n "diskoImagesScript" flake.nix (uses disko script for payload embedding)
7. grep -n "post-format-files" flake.nix (embeds compressed raw image)
8. grep -n "final.lib.nixosSystem" flake.nix (installer uses final.lib, not nixpkgs)
9. git status (clean)

Report PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-3`.
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

QEMU: Read from the user's existing config (same pattern as raw image).
The user must have qemu-guest profile in their config for this to work.

qemuEnabled = imagesConfig.qemu.enable or false;
qemu-image = if qemuEnabled then
  userConfig.config.system.build.images.qemu
else null;

ISO: Build a separate nixosSystem using the installercd profile.
This is the standard nixpkgs way to produce a bootable ISO.

isoEnabled = imagesConfig.iso.enable or false;
iso-image = if isoEnabled then
  (final.lib.nixosSystem {
    inherit system;
    modules = [
      "${final.path}/nixos/modules/profiles/installercd.nix"
    ];
  }).config.system.build.images.iso
else null;

NOTE: ISO uses "${final.path}/nixos/modules/profiles/installercd.nix" —
this is the correct nixpkgs module for ISO generation.
Do NOT use virtualisation.virtualbox.guest.enable.

Add both to the returned attrset. Defaults are false.

Commit: "feat: add QEMU QCOW2 and ISO image outputs"
```

**Verify:** Package attributes exist when enabled.

### Phase 4 Verification Gate

**Agent:** tpol-minimax

**Prompt:**
```
Verify Phase 4 (QEMU + ISO) of the nixinate image generation implementation.

Working directory: /speed-storage/repo/DarthPJB/nixinate
Branch: feat/image-generation

Check:
1. nix flake check --no-build
2. grep -n "qemu-image" flake.nix
3. grep -n "iso-image" flake.nix
4. grep -n "installercd.nix" flake.nix (correct ISO approach)
5. grep -n "qemu.enable or false" flake.nix (defaults off)
6. grep -n "iso.enable or false" flake.nix (defaults off)
7. git status (clean)

Report PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-4`.
**On fail:** Fix and re-verify.

---

## Phase 5: Closure Size Check

**Tag:** `v1.1.0-image-phase-5`
**Dependencies:** Phase 2 complete and tagged

### Step 5.1: Create size parsing helper

**Agent:** bellana-deepseek
**Files:** `lib/closure-size.nix` (new)

**Prompt:**
```
Create a size parsing helper at
/speed-storage/repo/DarthPJB/nixinate/lib/closure-size.nix.

Create the lib/ directory if needed.

{ lib, ... }:
let
  # Parse size strings like "20G", "1024M", "8G" to bytes
  parseSize = str:
    let
      matchResult = builtins.match "([0-9]+)([GMKgmk])?" str;
      num = builtins.fromJSON (builtins.head matchResult);
      suffix = if builtins.length matchResult > 1
               then builtins.elemAt matchResult 1
               else null;
      multiplier = if suffix == "G" || suffix == "g" then 1024*1024*1024
        else if suffix == "M" || suffix == "m" then 1024*1024
        else if suffix == "K" || suffix == "k" then 1024
        else 1; # bytes if no suffix
    in
      num * multiplier;
in
{
  nixinate.lib.parseSize = parseSize;
}

NOTE: Use builtins.match with optional suffix group, not separate regex calls.
Handle both uppercase and lowercase suffixes.

Commit: "feat: add size parsing helper for image size calculations"
```

**Verify:** File exists, parseSize handles "20G", "1024M", "8G".

### Step 5.2: Wire size validation into raw image build

**Agent:** bellana-deepseek
**Files:** `flake.nix`

**Prompt:**
```
Add image size validation to the raw image build in
/speed-storage/repo/DarthPJB/nixinate/flake.nix.

In the generateImages overlay, before building the raw image, validate
that the configured imageSize is large enough for ESP + swap + some root space.

In mkImagePackages, add:

# Size validation
sizeLib = import ./lib/closure-size.nix { inherit (final) lib; };
parseSize = sizeLib.nixinate.lib.parseSize;
imageSizeBytes = parseSize (imagesConfig.raw.imageSize or "20G");
espSizeBytes = parseSize (imagesConfig.raw.espSize or "1024M");
swapSizeBytes = parseSize (imagesConfig.raw.swapSize or "8G");
rootSizeBytes = imageSizeBytes - espSizeBytes - swapSizeBytes;
sizeValid = rootSizeBytes > 0;

Then wrap the raw-image output:
raw-image = if rawEnabled then
  assert sizeValid; userConfig.config.system.build.diskoImages
else null;

NOTE: assert is a STATEMENT, not an expression in parens.
The correct syntax is: assert sizeValid; <expression>
NOT: (assert sizeValid; <expression>)

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

Check:
1. nix flake check --no-build
2. cat lib/closure-size.nix (parseSize function, handles G/M/K)
3. grep -n "parseSize" flake.nix (wired into generateImages)
4. grep -n "assert sizeValid" flake.nix (correct assert syntax)
5. grep -n "rootSizeBytes" flake.nix (computes available root space)
6. git status (clean)

Report PASS or FAIL with details.
```

**On pass:** Tag `v1.1.0-image-phase-5`.
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
      url = "github:DarthPJB/nixinate";
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
        nixinate.nixosModules.image-gen
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

NOTE: Uses github:DarthPJB/nixinate (NOT Bargman-Tech).
User imports BOTH disko.nixosModules.disko AND nixinate.nixosModules.image-gen.

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

And import the image module in your nixosConfiguration:

```nix
imports = [
  disko.nixosModules.disko
  nixinate.nixosModules.image-gen
];
```

### Available Outputs

| Output | Command | Description |
|--------|---------|-------------|
| Raw image | `nix build .#<machine>-raw-image` | dd-able disk image |
| Compressed | `nix build .#<machine>-raw-image-zstd` | zstd-compressed (level 3) |
| Installer | `nix build .#<machine>-installer-image` | Bootable USB installer |
| QEMU | `nix build .#<machine>-qemu-image` | QCOW2 (requires qemu profile) |
| ISO | `nix build .#<machine>-iso-image` | Bootable ISO |

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

Check:
1. cat examples/flake-with-images.nix (exists, shows genImages)
2. grep -n "genImages" examples/flake-with-images.nix
3. grep -n "DarthPJB/nixinate" examples/flake-with-images.nix (correct URL)
4. grep -n "Image Generation" README.md
5. grep -n "raw-image" README.md
6. grep -n "image-gen" README.md (shows module import)
7. git status (clean)

Report PASS or FAIL with details.
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

**Total:** 15 steps, 6 verification gates, 6 tags.

---

## Changes from v1 (Based on Adversarial Reviews)

1. **Raw images read from user's existing config** — no derived nixosSystem
   (fixes tpol-gpt concern about not including user's config)
2. **Only installer uses separate nixosSystem** — it's a genuinely different system
3. **Fixed Nix syntax** — assert as statement, lib.filter not lib.remove,
   final.lib.nixosSystem not nixpkgs.lib.nixosSystem
4. **Fixed ISO approach** — uses installercd.nix, not virtualbox guest
5. **Fixed example URL** — DarthPJB/nixinate, not Bargman-Tech
6. **Disko default uses lib.mkDefault** — not brittle mkIf == {} check
7. **Uses writeShellApplication** — per prime directive 18
8. **Auto-dd re-run preserved** — known good behavior from reference implementation
