# Adversarial Review: tpol-xai (Systems Architecture)

## Summary

The image generation action plan extends nixinate (a deployment script generator) to also produce disk images and installers via a `genImages` overlay function parallel to the existing `genDeploy`. It relies heavily on derived `nixosSystem` evaluations inside the overlay, automatic disko injection, a default GPT/ESP→swap→root layout, zstd compression, and an auto-dd installer mechanism.

**Core finding**: The architecture is ambitious but fragile. The overlay + derived-config pattern introduces significant eval-time complexity, potential module system conflicts, and maintenance burden. While disko integration is conceptually sound, the implementation details (especially installer wiring and size checking) contain gaps that will cause runtime/build failures. The plan partially aligns with NixOS patterns but deviates from community-preferred approaches like `nixos-generators` or direct flake `packages` exposure.

**Verdict: CONDITIONAL PASS** — Proceed only after addressing the architectural concerns in Sections 2 and 3. The plan can be salvaged with modifications; a full rewrite of the generation mechanism is recommended.

## Architectural Concerns

### 1. Overlay Pattern for genImages Is Suboptimal

The existing `generateApps` lives in an overlay (`overlays.default.nixinate.generateApps`) and is exposed via `lib.genDeploy`. Replicating this for images (`generateImages` + `lib.genImages`) is consistent with the current codebase but architecturally questionable:

- **Overlay pollution**: Overlays are intended for package set modifications. Injecting a large attrset of machine-specific image derivations into every package set (even when unused) adds eval overhead and namespace clutter.
- **Better alternative**: Expose `genImages` directly as a pure library function in `flake.outputs.lib` (or `self.lib`) that returns an attrset of packages. This avoids the overlay entirely for image generation. The current `lib.genDeploy` pattern itself is a workaround for the lack of a clean "apps generator" API in flakes.
- **Eval cost**: `forAllSystems` + `nixpkgsFor` already imports nixpkgs multiple times. Adding image generation (which triggers full `nixosSystem` evaluations per machine) compounds this. Users calling `nix flake show` or `nix eval` will pay the cost even if they only want deployment scripts.

**Recommendation**: Decouple image generation from the overlay. Keep `generateApps` for backwards compat but make `genImages` a standalone `lib` function that users invoke as `packages = nixinate.lib.genImages.x86_64-linux self;`.

### 2. Derived nixosConfiguration Approach Is Problematic

The plan creates new `nixpkgs.lib.nixosSystem` instances inside `mkImagePackages` (Steps 2.1, 3.4, 4.1) for every enabled image type:

```nix
rawDerivedConfig = nixpkgs.lib.nixosSystem {
  modules = [
    disko.nixosModules.disko
    ./modules/images/default.nix
    ./modules/images/disko-default.nix
    { _module.args.nixinate = userConfig._module.args.nixinate; }
  ];
};
```

**Issues**:
- **Module system duplication**: Each derived config re-evaluates a large portion of the user's config (via the nixinate arg passthrough) plus new modules. This can cause option conflicts, especially with `disko.devices` (the default schema uses `mkIf (config.disko.devices == {})` which is racy).
- **_module.args hack**: Manually injecting `_module.args.nixinate` bypasses the normal module argument system. If the user's config uses `config.nixinate...` or special args, it may not compose cleanly.
- **Circularity risk**: The user's original `nixosConfiguration` may already import disko or define images options. Re-deriving can lead to double-import warnings or option collisions.
- **Performance**: Full system evaluations inside a flake output generator scale poorly with many machines or complex configs.

**Better approach**: 
- Provide a `nixinateImageModule` that users import directly into their existing `nixosConfiguration`.
- Use `config.system.build.diskoImages` from the *user's* evaluated config when possible, falling back to a minimal wrapper only for missing disko.
- Or adopt `nixos-generators` as a dependency (it already solves "turn nixosConfiguration into packages").

### 3. Disko Integration — API and Timing Concerns

The plan assumes:
- `config.system.build.diskoImages` (raw image)
- `config.system.build.diskoImagesScript` + `--post-format-files` (installer payload embedding)

**Potential problems**:
- Disko's image API is documented but somewhat unstable across versions. `diskoImages` requires the disko module to be imported and a `disko.devices` definition; the `device = "/dev/null"` pattern works but is an implementation detail.
- `--post-format-files` is specific to the QEMU-based script mode (`diskoImagesScript`). The action plan Step 3.4 uses it to embed the zstd payload, but the path handling (`install/image.raw.zst`) and output naming (`autoinstaller.raw`) must exactly match disko's expectations or the script will fail silently.
- The default schema in `disko-default.nix` sets `device = "/dev/null"` unconditionally when `disko.devices == {}`. This works for image builds but will break any user who has a partial disko config (the `== {}` check is too naive).
- Installer disko schema (Step 3.4) hardcodes a second disk (`autoinstaller`) with different sizing (512M ESP, no swap). This creates two different disko configs in one evaluation, which disko may not handle gracefully.

**Risk**: Builds will fail at the disko layer with opaque QEMU errors rather than clear Nix errors.

### 4. Partition Layout — Mostly Correct but Inflexible

ESP → swap → root (ext4, 100%) is a reasonable default for UEFI systems and allows `growpart` + `resize2fs` to expand the root after dd.

**Concerns**:
- Swap is placed *before* root so root can expand. This is correct for the post-dd resize logic.
- However, many modern systems prefer swap as a file, zram, or no swap at all. The 8G default is arbitrary.
- ESP at 1024M is generous (512M is usually sufficient); the plan acknowledges this but doesn't make it configurable in v1.
- No support for hybrid MBR, btrfs, LUKS, or ZFS in the default schema. Users with existing disko configs are fine; pure default users are locked into ext4.

The layout is acceptable for v1 but should be documented as "opinionated default."

### 5. Closure Size Check Is Incomplete

Phase 5 implements only a negative-size guard (`rootSizeBytes > 0`). The architecture plan describes a proper `closureInfo` comparison that would catch "closure exceeds imageSize" early.

**Gap**: The action plan's check will not prevent the common failure mode (image too small for the closure). Users will still see opaque "out of space" errors from inside the QEMU VM spawned by disko. The `lib/closure-size.nix` parser is also naive (regex-based, no unit handling for "G" vs "GiB").

**Recommendation**: Implement the full closure size check using `pkgs.closureInfo` before invoking disko, or defer the feature entirely and document the limitation.

### 6. Installer Complexity and Brittleness

The auto-dd installer (Steps 3.1–3.3) copies a large shell script + systemd service from a reference implementation. While functional, it introduces:
- Hardcoded assumptions about target device (`/dev/nvme0n1`), min size (64G), and shutdown behavior.
- Reliance on `kmscon` + journalctl tailing for UX — this is heavy for an installer.
- No verification step after dd (`cmp` or checksum).

This is acceptable for a reference but should be marked as "experimental" in docs.

## Alternative Approaches

1. **Use nixos-generators**: Instead of custom `genImages` + derived configs, depend on `github:nix-community/nixos-generators` and map its outputs. This is the community standard for "configuration → image package."

2. **Direct disko exposure**: If the user already uses disko, simply re-export `config.system.build.diskoImages` under a conventional package name. No derived config needed.

3. **Separate image flake**: Recommend users create a small `images.nix` that imports their main config + disko + a thin nixinate image module. This keeps the core nixinate flake small.

4. **Avoid overlay for images**: Provide `nixinate.mkImagePackages` as a pure function that takes a nixosConfiguration and returns packages. Users compose it in their own `perSystem` or `packages` attrset.

## Alignment with NixOS Patterns

- **Positive**: Use of disko for declarative images, zstd compression research, `forAllSystems` helper, and per-machine `_module.args` are all idiomatic.
- **Negative deviations**:
  - Community prefers exposing image packages directly from `outputs.packages` or via `nixos-generators`, not via a `lib.gen*` function that must be called manually.
  - Heavy use of overlays for non-package concerns (deployment scripts, image generators) is unusual.
  - The "installer with embedded payload via --post-format-files" pattern is clever but not widely used; most projects ship separate "installer ISO" and "raw image" artifacts.
  - No use of `system.build.isoImage` or `sdImage` from nixpkgs, which are battle-tested.

The plan is internally consistent with nixinate's existing (unconventional) architecture but does not follow the most common NixOS community patterns for image generation.

## Verdict: CONDITIONAL PASS

The plan is executable but carries architectural risk. It can proceed if the following are addressed before or during implementation:

1. Reconsider the overlay/derived-config mechanism (prefer pure lib function or nixos-generators).
2. Strengthen the disko default schema guard and document the `--post-format-files` contract.
3. Either implement a real closure size check or explicitly defer it with a warning.
4. Add a smoke-test verification step (build + boot in QEMU) before Phase 6 docs.

Without these changes, the implementation is likely to produce packages that fail to build for non-trivial configurations, leading to user frustration and maintenance burden on the nixinate maintainers.

**Recommended next step**: Prototype the `genImages` function in isolation (outside the overlay) against a minimal test configuration before committing to the full 16-step plan.
