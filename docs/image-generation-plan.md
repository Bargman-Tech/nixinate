# Phase 5: Image and Installer Generation — Implementation Plan

**Status:** Draft
**Date:** 2026-06-26
**Scope:** Nixinate v1.x — MNGA Phase 5

---

## Overview

Nixinate generates deployment scripts from a user's `nixosConfiguration`. Phase 5
extends this to also generate **disk images** and **bootable installers** from the
same configuration — enabling offline provisioning, bare-metal deployment, and
air-gapped installation.

The user provides a complete `nixosConfiguration` (including disko schema, hardware
config, desktop, apps, authentication — everything). Nixinate produces buildable
image outputs from that config. Nixinate does not assemble system configurations;
it consumes them.

---

## User Interface

Image generation is controlled via the existing `_module.args.nixinate` block.
Boolean `enable` flags control which image types are produced. Defaults are
sane — a raw disk image and an installer are produced unless explicitly disabled.

To enable image outputs, the user adds a line to their flake:

```nix
outputs = { self, nixpkgs, nixinate }: {
  apps = nixinate.lib.genDeploy.x86_64-linux self;
  packages = nixinate.lib.genImages.x86_64-linux self;  # <-- new

  nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem { ... };
};
```

`genImages` reads `_module.args.nixinate` from each `nixosConfiguration` and
produces the requested image packages. Users who don't add this line get no
image outputs — the `images` config is inert without it.

### Module Args

```nix
_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";

  # Image generation (all optional, defaults shown)
  images = {
    raw.enable = true;       # raw disk image (dd-able to NVMe/SSD)
    installer.enable = true; # bootable USB installer with embedded image
    qemu.enable = false;     # QCOW2 for QEMU/VM testing
    iso.enable = false;      # bootable ISO image
  };
};
```

**Defaults:** `raw` and `installer` enabled. `qemu` and `iso` disabled.
Adding the `images` block is optional — these are the defaults when
`genImages` is called. Users who only want deployment scripts (existing
behaviour) add only `genDeploy` and get no change.

### Future Extensions (not v1)

```nix
images = {
  raw = {
    enable = true;
    compression = "zstd";      # none, zstd (default: zstd)
    zstdLevel = 3;             # 1-19 (default: 3 per compression research)
    partitionTable = "efi";    # efi, hybrid, legacy (default: efi)
    format = "raw";            # raw, qcow2 (default: raw)
  };
  installer = {
    enable = true;
    payload = "image";         # embeds the raw image as payload
    minDiskSize = "64G";       # minimum target disk size
  };
};
```

These extensions are explicitly deferred. v1 uses the core sizing parameters
(`imageSize`, `espSize`, `swapSize`) with sane defaults.

---

## Architecture

### Core Principle

Nixinate consumes the user's `nixosConfiguration` and produces derived
configurations for image outputs. The user's config is never modified.

### Disko Integration

Disko provides the disk image generation infrastructure:
- `config.system.build.diskoImages` — builds raw disk images in the nix sandbox
- `config.system.build.diskoImagesScript` — produces a script that builds images
  in a QEMU VM (supports `--post-format-files` for embedding payloads)

**Disko import handling:**
- If the user's `nixosConfiguration` already imports `disko.nixosModules.disko`,
  nixinate uses it as-is.
- If the user has NOT imported disko, nixinate adds it automatically when image
  generation is enabled.
- If the user has no disko schema (`disko.devices` not defined), nixinate provides
  a sane default: GPT partition table, swap (at disk start, so ext4 root can
  expand), 512M ESP (vfat), root ext4 (remaining space).

This is idempotent — double-importing disko is safe (NixOS modules are deduped).

### Default Disko Schema

When the user hasn't defined `disko.devices`, nixinate provides this layout:

```nix
disko.devices.disk.main = {
  device = "/dev/null"; # overridden by image builder
  type = "disk";
  content = {
    type = "gpt";
    partitions = {
      ESP = {
        # ESP MUST be first — UEFI requires ESP in the first 1M block
        type = "EF00";
        size = "1024M";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = [ "umask=0077" ];
        };
      };
      swap = {
        size = "8G";
        content = {
          type = "swap";
          randomEncryption = true;
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
```

**Partition order:** ESP (first, UEFI requirement) → swap → root (last,
can expand to fill target disk).

### Configurable Parameters

The default disko schema provides sane defaults, but users can override
the principal sizing parameters:

```nix
images = {
  raw = {
    enable = true;
    imageSize = "20G";    # total raw image size (default: 20G)
    espSize = "1024M";    # ESP partition size (default: 1024M)
    swapSize = "8G";      # swap partition size (default: 8G)
  };
};
```

**Defaults:**
- `imageSize = "20G"` — total disk image size
- `espSize = "1024M"` — ESP partition (UEFI requirement, minimum 512M)
- `swapSize = "8G"` — swap partition (minimum for reasonable operation)

**Known issue:** If the raw image size is smaller than the final closure,
the image will not fit. This is a known problem — to be discussed separately.

### Output Generation

For each `nixosConfiguration` that has `images.*.enable = true`, nixinate
generates buildable package outputs:

#### 1. Raw Disk Image (`images.raw`)

**Input:** User's `nixosConfiguration` (with disko schema)
**Output:**
- `packages.x86_64-linux.<machine>-raw-image` — uncompressed raw disk image
- `packages.x86_64-linux.<machine>-raw-image-zstd` — zstd-compressed (derived from raw)

**Mechanism:** `config.system.build.diskoImages`

The raw image is a complete, dd-able disk image containing the user's full
NixOS system. The uncompressed raw image is the primary output. The
zstd-compressed version is derived from it (simple chain: raw → zstd).

#### 2. Installer Image (`images.installer`)

**Input:** User's raw image + minimal NixOS installer shell
**Output:** `packages.x86_64-linux.<machine>-installer-image`
**Mechanism:** Derived `nixosConfiguration` with auto-dd service

The installer is a separate, minimal NixOS system that:
1. Boots from USB (GRUB + Plymouth branded)
2. Auto-detects the target NVMe
3. Decompresses and writes the raw image via `zstd -d -c | dd`
4. Relocates GPT backup header (`sgdisk -e`)
5. Grows root partition and resizes filesystem (`growpart + resize2fs`)
6. Creates swap partition
7. Shuts down

The raw image is embedded as a zstd-compressed payload at `/install/image.raw.zst`
using `diskoImagesScript --post-format-files`.

**Installer UX:**
- kmscon with autologin tails the install journal on console
- Plymouth splash during boot
- Clean shutdown with "Remove USB, then power on" message

#### 3. QEMU Image (`images.qemu`)

**Input:** User's `nixosConfiguration` with QEMU guest profile
**Output:** `packages.x86_64-linux.<machine>-qemu-image`
**Mechanism:** `config.system.build.images.qemu`

QCOW2 image for local VM testing. Requires the user's config to include
`"${modulesPath}/profiles/qemu-guest.nix"` or equivalent.

#### 4. ISO Image (`images.iso`)

**Input:** User's `nixosConfiguration` with VirtualBox/ISO profile
**Output:** `packages.x86_64-linux.<machine>-iso-image`
**Mechanism:** `config.system.build.images.iso`

Bootable ISO image. Useful for physical media or PXE boot scenarios.

---

## Implementation Details

### File Structure (within nixinate)

```
nixinate/
├── flake.nix                    # existing — add disko input
├── modules/
│   └── images/
│       ├── default.nix          # image generation orchestrator
│       ├── disko-default.nix    # default disko schema (GPT/ESP/swap/ext4)
│       ├── installer.nix        # installer NixOS module (boot, grub, plymouth)
│       ├── auto-dd.nix          # auto-dd-install systemd service module
│       └── auto-dd-install.sh   # dd + post-processing shell script
└── docs/
    └── image-generation.md      # user-facing documentation
```

### Flake Changes

Add disko as an input:

```nix
inputs = {
  nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  disko = {
    url = "github:nix-community/disko";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

The overlay must pass disko through to the image generation modules.

### Image Generation Flow

```
User's nixosConfiguration.myMachine
    │
    ├─── images.raw.enable = true?
    │       │
    │       ├─── Add disko module if missing
    │       ├─── Add default disko schema if missing
    │       │       (GPT: ESP → swap → root ext4)
    │       └─── Build config.system.build.diskoImages
    │               │
    │               ├─── packages.<machine>-raw-image       (uncompressed)
    │               │
    │               └─── zstd -3 -T0 (compress raw)
    │                       └─── packages.<machine>-raw-image-zstd
    │
    ├─── images.installer.enable = true?
    │       │
    │       ├─── Create derived nixosConfiguration:
    │       │       imports = [
    │       │         disko.nixosModules.disko
    │       │         installer.nix      # boot, grub, plymouth
    │       │         auto-dd.nix        # systemd auto-install service
    │       │         accounts.nix       # installer user accounts
    │       │       ];
    │       │       disko.devices.disk.autoinstaller = { ... };
    │       │
    │       ├─── Build installer diskoImage with --post-format-files
    │       │       (embeds compressed raw image at /install/image.raw.zst)
    │       └─── packages.<machine>-installer-image
    │
    ├─── images.qemu.enable = true?
    │       └─── Build config.system.build.images.qemu
    │               └─── packages.<machine>-qemu-image
    │
    └─── images.iso.enable = true?
            └─── Build config.system.build.images.iso
                    └─── packages.<machine>-iso-image
```

### GRUB Theming Problem

The user identified that upstream nixpkgs forces its own GRUB theme. The
installer module must explicitly override GRUB configuration to prevent
nixpkgs defaults from leaking through. This is handled in `installer.nix`:

```nix
boot.loader.grub = {
  enable = true;
  device = "nodev";
  efiSupport = true;
  efiInstallAsRemovable = true;
  # User can override these via their nixosConfiguration
  # theme, splashImage, etc. are left unset unless user provides them
};
```

The user's `nixosConfiguration` may include custom GRUB theming (e.g.,
custom grub theme from branding assets). Nixinate's installer module
sets the minimum required GRUB config and lets the user's config take
precedence for theming.

### Auto-DD Script

Based on the working reference implementation (`shell/auto-dd-install.sh`).
Key behaviours:
- Stops display manager, Plymouth, background services for maximum I/O
- Validates target device (not mounted, not current root, size check)
- `zstd -d -c | dd of=$TARGET bs=4M status=progress`
- `sgdisk -e` to relocate GPT backup header
- `growpart` + `resize2fs` to expand root into remaining space
- Shutdown with user message

**Swap is in the disko schema** (at disk start), not created post-dd.
The raw image already contains swap. The ext4 root partition follows swap
and can expand to fill the disk because it is the last partition.

Target device defaults to `/dev/nvme0n1`. Future versions will support
kernel cmdline override (`nixos.install.target=/dev/sda`).

### Zstd Compression Settings

Based on zstd compression research (shared/zstd-compression-research.md):
- **Level 3** (default): 100x faster than level 19, <3% size difference
- **Parallel compression** (`-T0`): uses all cores during build
- **Decompression speed** is constant across all levels (>5GB/s)
- A 16GB raw image with 6GB data compresses to ~4GB at level 3

---

## Reference Implementation

The working implementation exists in:
`/speed-storage/repo/SQUIRGLE_MEN/nix-workstation-image`

Key files:
- `flake.nix` — full ecosystem with disko, image outputs, zstd compression
- `machines/demo/default.nix` — disko schema for raw image (GPT/ESP+ext4)
- `machines/installer/default.nix` — installer base (GRUB, Plymouth, firmware)
- `machines/installer-auto-dd/default.nix` — auto-dd systemd service
- `shell/auto-dd-install.sh` — dd + post-processing script
- `machines/cinnamon/` and `machines/cinnamon-mac/` — desktop configs

The reference implementation produces:
- `cinnamon-pc-demo-disk-image` — raw disko image
- `cinnamon-pc-installer-zstd-image` — zstd-compressed payload
- `cinnamon-pc-auto-installer-disk-image` — bootable installer with embedded payload
- `cinnamon-pc-iso-image` — bootable ISO
- `cinnamon-pc-qcow2-image` — QEMU image

---

## Adversarial Concerns (from prior analysis)

### Addressed

| Concern | Resolution |
|---------|------------|
| Runs on every boot | Installer boots once, installs, shuts down. No re-run risk. |
| No write verification | zstd decompression + dd with `conv=fsync`. Future: add `cmp` verification. |
| GPT backup header corruption | `sgdisk -e` after dd relocates header to actual disk end. |
| UUID conflicts | Deferred — not critical for single-disk provisioning. |
| Hardcoded `/dev/nvme0n1` | Acceptable for v1. Future: kernel cmdline override. |
| GRUB theming | Nixinate sets minimal GRUB config; user overrides for theming. |

### Deferred

| Concern | Status |
|---------|--------|
| Post-install config injection for `nixos-rebuild` | Not needed. `/etc/nixos` is legacy Nix. |
| iPXE network boot integration | Phase 6 (MNGA). |
| Cross-arch image generation | Phase 6. disko supports binfmt. |
| LUKS/btrfs/ZFS partition layouts | Future extension via `images.raw.partitionTable`. |
| Interactive disk selection UI | Future. v1 targets known hardware. |

---

## Milestones

### M1: Raw Image Output
- Add disko input to nixinate flake
- Implement `genImages` function (parallel to `genDeploy`)
- Implement `images.raw.enable` → `diskoImages` output
- Handle disko import (add if missing, idempotent)
- Default disko schema (GPT: ESP → swap → root ext4)
- Zstd compression (level 3) derived from raw output
- **Exit:** `nix build .#packages.<machine>-raw-image` produces a raw disk image,
  `nix build .#packages.<machine>-raw-image-zstd` produces the compressed version

### M2: Installer Image
- Implement `images.installer.enable`
- Create installer NixOS module (boot, grub, plymouth)
- Create auto-dd module and shell script
- Embed compressed raw image via `--post-format-files`
- **Exit:** `nix build .#packages.<machine>-installer-image` produces a bootable installer USB image

### M3: QEMU and ISO Outputs
- Implement `images.qemu.enable` → `system.build.images.qemu`
- Implement `images.iso.enable` → `system.build.images.iso`
- **Exit:** Both outputs build and boot correctly

### M4: Documentation and Testing
- User-facing documentation in README
- Example flake with image generation
- Smoke test: build installer, boot in QEMU, verify installation
- **Exit:** Documentation complete, example works end-to-end

---

## Open Questions

1. **Should nixinate re-export disko?** If nixinate adds disko as an input,
   users get it transitively. But users may want their own disko version.
   Recommendation: follow nixinate's existing pattern (`inputs.nixpkgs.follows`).

2. **Multiple machines with different image configs?** Each `nixosConfiguration`
   has its own `_module.args.nixinate.images` block. No coupling between machines.

3. **CI/CD integration?** Images are buildable packages. CI can `nix build` them
   directly. No special nixinate CI support needed.

---

## References

- [Disko — Declarative disk partitioning](https://github.com/nix-community/disko)
- [Disko image generation](https://github.com/nix-community/disko/blob/master/docs/disko-images.md)
- [disko-install](https://github.com/nix-community/disko/blob/master/docs/disko-install.md)
- [Zstd compression research](/speed-storage/opencode/llm/shared/zstd-compression-research.md)
- [DD installer architectural synthesis](/speed-storage/opencode/llm/shared/dd-installer-architectural-synthesis.md)
- [DD installer adversarial analysis](/speed-storage/opencode/llm/shared/dd-installer-adversarial-analysis.md)
- [QEMU test harness plan](/speed-storage/opencode/llm/shared/qemu-bargman-test-harness.md)
- [MNGA plan](docs/MNGA-plan.md) — Phase 5
- [Reference implementation](/speed-storage/repo/SQUIRGLE_MEN/nix-workstation-image)
