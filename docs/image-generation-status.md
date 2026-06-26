# Image Generation — Status Report

**Date:** 2026-06-26
**Branch:** `feat/image-generation`

---

## Current State

### Nixinate (`feat/image-generation`)

**Tags pushed:**
- `v1.1.0-image-phase-1` through `v1.1.0-image-phase-6`

**Uncommitted change:** `flake.nix` modified (image-gen imports disko, applies default schema)

**Files created:**
- `modules/images/default.nix` — nixinate.images options + default disko schema
- `modules/images/disko-default.nix` — unused (schema moved into default.nix)
- `modules/images/installer.nix` — GRUB+EFI minimal boot
- `modules/images/auto-dd.nix` — systemd auto-dd service + kmscon
- `modules/images/auto-dd-install.sh` — dd + growpart/resize2fs script
- `lib/closure-size.nix` — size parsing helper
- `examples/flake-with-images.nix` — example usage

**Exports:**
- `lib.genDeploy` — existing deployment scripts
- `lib.genImages` — new image package generator
- `nixosModules.image-gen` — NixOS module (imports disko + options + defaults)
- `schemas.lib` / `schemas.overlays` / `schemas.nixosModules` — flake schemas

### NixOS-Configuration Worktree (`/tmp/nixinate-image-test`)

**Branch:** `test-image-generation`
**Changes:** 2 modifications to `flake.nix`

1. nixinate input: `github:Bargman-Tech/nixinate` → `path:/speed-storage/repo/DarthPJB/nixinate`
2. Added `nixinate.nixosModules.image-gen` to mkX86_64 modules

**Tested with alpha-three:**
- `config.nixinate.images` evaluates with correct defaults
- `config.disko.devices.disk.main` exists with correct partition layout
- `genImages` produces `alpha-three-raw-image`, `-zstd`, `-installer-image`

---

## Current Problem

Raw image build fails because `hardware-configuration.nix` defines `fileSystems."/".device` with a UUID, and disko defines it with a partlabel. These conflict at the same priority.

Attempted fix with `lib.mkForce` — **wrong**. Hardware-configuration.nix is the correct source for the live system. Overriding it breaks production.

**Root cause:** `image-gen` module is imported into the production mkX86_64, which includes `hardware-configuration.nix`. The disko schema and hardware-configuration.nix both define the same filesystem at the same priority.

**Options:**
1. genImages creates derived configs (not the user's existing config) — was rejected earlier for not including user's modules
2. image-gen only imported when building images, not in production config
3. Disko schema uses lower priority so hardware-configuration.nix wins for live, disko wins for image builds
4. Separate image nixosConfigurations that exclude hardware-configuration.nix

---

## Pending

- Commit nixinate changes (flake.nix + default.nix updates)
- Fix filesystem conflict
- Verify raw image actually builds
- Verify installer image builds
- Clean up worktree
- Push all changes
