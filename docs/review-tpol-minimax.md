# Adversarial Review: tpol-minimax

## Summary

The action plan has a solid architectural foundation and correctly sequences the work into manageable phases. However, it contains multiple critical issues ranging from incorrect Nix syntax in prompt templates, references to non-existent attributes, wrong module paths for disko, missing configuration, and broken verification commands. Most issues are in the Nix code snippets embedded in the prompts — the agent `bellana-deepseek` would generate broken code if following these prompts verbatim.

**Verdict: FAIL**

The plan cannot be executed as written. Critical Nix syntax errors and incorrect attribute references must be fixed before execution.

---

## Critical Issues

### C1: `genImages` stub references non-existent attribute

**Location:** Step 1.2, Prompt

**Problem:** The stub uses `nixpkgsFor.${system}.generateImages`:

```nix
lib.genImages = forAllSystems (system: pkgs: nixpkgsFor.${system}.generateImages);
```

But `nixpkgsFor.${system}` is a Nixpkgs package set. It does not have a `generateImages` attribute. The only image-related function in nixpkgs is `nixosSystem`, not `generateImages`. The reference `generateApps` works because it accesses `lib.genDeploy` from the flake outputs (via `nixpkgsFor.${system}.generateApps`), but `generateApps` is itself defined inside the same overlay and wraps `final.writeShellApplication`. There is no analogous `generateImages` function anywhere in scope.

The verification at Step 1.2 expects:
```
nix eval '.#lib.genImages'
```
to return a function. But the stub constructs an attrset (not a function), and even if it did return a function, it would reference a non-existent `nixpkgsFor.${system}.generateImages`.

**Fix:** The stub should follow the same pattern as `generateApps` — define `generateImages` inside the overlay as a function that takes a flake and returns an attrset of image packages. The prompt should say:

```nix
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
```

And `lib.genImages` should call this overlay function, not `nixpkgsFor.${system}.generateImages`.

---

### C2: Broken Nix syntax in size assertion

**Location:** Step 5.2, Prompt, line 814

**Problem:** The prompt contains:

```nix
raw-image = if rawEnabled then
  (assert sizeValid; rawDerivedConfig.config.system.build.diskoImages)
else null;
```

This is invalid Nix syntax. In Nix, `assert <expr>;` is a statement that evaluates to the assert condition's boolean value, not an expression that can be placed inside parentheses as part of an attribute value chain. The correct form would be:

```nix
raw-image = if rawEnabled then
  assert sizeValid; rawDerivedConfig.config.system.build.diskoImages
else null;
```

Or alternatively, using a let binding:
```nix
raw-image = if rawEnabled then
  let _ = assert sizeValid; in rawDerivedConfig.config.system.build.diskoImages
else null;
```

The current syntax would produce a parse error.

**Fix:** Change the assertion syntax to a proper statement.

---

### C3: Broken `lib.remove ""` pattern in genImages overlay

**Location:** Step 1.2 Prompt, Step 2.1 Prompt, Step 3.4 Prompt

**Problem:** The existing code in `generateApps` uses:
```nix
validMachines = final.lib.remove "" (final.lib.forEach machines
  (x: final.lib.optionalString (condition) "${x}"));
```

This pattern is **incorrect**. `lib.forEach` takes a list and a function, and returns a list. `lib.optionalString` returns a string (empty when false, the string when true). So `lib.forEach machines (x: lib.optionalString ...)` returns a list of strings with empty strings interspersed. Then `lib.remove ""` filters those out.

But `lib.remove` is not the right function. It removes elements *equal* to `""` from a list, but since `lib.forEach` already produces a list, this works — albeit in a convoluted way. However, `lib.remove` does not exist in Nixpkgs lib. The correct function is `lib.filter`.

The existing code in `generateApps` at line 33 of `flake.nix` uses this same broken pattern:
```nix
validMachines = final.lib.remove "" (final.lib.forEach machines (x: final.lib.optionalString (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}" ));
```

Since `lib.remove ""` doesn't exist, this would fail at eval time. But since `flake.nix` currently evaluates, either `lib.remove` exists in some context, or the existing code is also broken and has never been tested with multi-machine configurations.

**Fix:** The plan should use the correct pattern. The simplest is:
```nix
validMachines = lib.filter (x: x != "") (lib.forEach machines
  (x: lib.optionalString (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}"));
```
Or using `lib.concatMap`:
```nix
validMachines = lib.concatMap (x: lib.optionalString (flake.nixosConfigurations."${x}"._module.args ? nixinate) [ x ]) machines;
```

---

### C4: Wrong nixpkgs reference in generateImages inner function

**Location:** Step 2.1, Prompt, inside `mkImagePackages`

**Problem:** The prompt says:
```nix
rawDerivedConfig = if rawEnabled then
  (nixpkgs.lib.nixosSystem {
```

But `nixpkgs` is not bound inside the `mkImagePackages` let binding. It exists in the outer scope (the flake's `nixpkgs` input), but inside `mkImagePackages` (which is inside the overlay), `nixpkgs` is not defined. The inner function shadows it with nothing.

The existing `generateApps` correctly uses `final.lib` (e.g., `final.lib.getExe`, `final.lib.optionalString`). The prompt should use `nixpkgs.lib.nixosSystem` but `nixpkgs` is out of scope. The fix should reference the outer scope's `nixpkgs` parameter directly or use `final.lib` for lib functions.

If `nixpkgs` in the prompt is meant to refer to `prev` (the base nixpkgs before overlay), it should be `prev.lib.nixosSystem`. If it's meant to be the post-overlay version, it should be `final.lib.nixosSystem` (but `final` is a package set, not nixpkgs lib).

**Fix:** Use `prev.lib.nixosSystem` since `prev` is the base nixpkgs passed to the overlay, and `nixosSystem` is a lib function.

---

### C5: Installer module missing `efiInstallAsRemovable`

**Location:** Step 3.1, Prompt

**Problem:** The installer NixOS module template in the prompt is missing `efiInstallAsRemovable = true`:

```nix
boot.loader.grub = {
  enable = true;
  device = "nodev";
  efiSupport = true;
  efiInstallAsRemovable = true;  # <-- MISSING
  timeoutStyle = lib.mkForce "menu";
};
```

The reference at `/speed-storage/repo/SQUIRGLE_MEN/nix-workstation-image/machines/installer/default.nix` includes `efiInstallAsRemovable = true`. Without this flag, the installer may fail to boot on systems where the firmware requires the bootloader to be installed in the removable EFI path (e.g., some Dell laptops, independent BIOS implementations).

**Fix:** Add `efiInstallAsRemovable = true;` to the GRUB config in the installer module prompt.

---

### C6: Disko autoinstaller config uses wrong module path

**Location:** Step 3.4, Prompt

**Problem:** The prompt defines:
```nix
{ disko.devices.disk.autoinstaller = {
    device = "/dev/null";
    type = "disk";
    content = { ... };
    imageSize = "7800M";
  };
}
```

But `disko.devices.disk` in disko's module system is an **attrset of submodules**, where each key is a disk name. The module path `disko.devices.disk.autoinstaller` is correct for naming the disk. However, the plan's `disko-default.nix` uses `disko.devices.disk.main` for the default schema. This creates two separate disk definitions (`main` and `autoinstaller`) that would coexist when both modules are imported.

More critically, the plan imports `disko-default.nix` into the raw image build (which defines `disko.devices.disk.main`) but does NOT import it into the installer build. The installer's `disko.devices.disk.autoinstaller` is defined inline. The question is whether disko can handle two disk definitions (`main` and `autoinstaller`) in the same configuration, or whether it expects only one disk.

If disko supports multiple disks (it does — `disko.devices.disk` is an attrset), then both would be built. But the plan only wants the `autoinstaller` disk for the installer, not the `main` disk from `disko-default.nix`. Since `disko-default.nix` is not imported for the installer, only `autoinstaller` exists there — but this raises the question of why `disko-default.nix` is imported for the raw image at all, if the user hasn't defined their own disko config.

**Fix:** Clarify the disko module import strategy. If the user has not defined `disko.devices`, the default schema should be used as the *only* disk, not as an additional one. The disko module import in `mkImagePackages` should check whether the user has provided their own `disko.devices.disk` configuration and only inject the default if none exists.

---

### C7: Installer ISO uses wrong VirtualBox guest approach

**Location:** Step 4.1, Prompt

**Problem:** The ISO configuration adds:
```nix
{ virtualisation.virtualbox.guest.enable = true; }
```

This does not produce a bootable ISO. The `virtualisation.virtualbox.guest` module is for running NixOS *inside* a VirtualBox VM as a guest. It does not configure the system to produce an ISO image.

To produce an ISO, nixpkgs uses `config.system.build.images.iso`, which is generated from the `iso` profile module (`nixos/modules/profiles/installercd.nix` or similar). Adding `virtualisation.virtualbox.guest.enable = true` is the wrong approach.

**Fix:** Either remove the ISO output from Phase 4 (defer to a future phase that properly implements ISO generation via nixpkgs's image building infrastructure), or use the correct approach:
```nix
{ imports = [ "${nixpkgs}/nixos/modules/profiles/installercd.nix" ]; }
```
This is the standard way to produce a minimal bootable ISO in nixpkgs.

---

### C8: Example flake references wrong nixinate URL

**Location:** Step 6.1, Prompt

**Problem:** The example uses:
```nix
nixinate = {
  url = "github:Bargman-Tech/nixinate";  # WRONG
  inputs.nixpkgs.follows = "nixpkgs";
};
```

This references `Bargman-Tech/nixinate`, which is not the correct owner/path. The actual repository is `DarthPJB/nixinate`. Using `github:Bargman-Tech/nixinate` would fetch a different, unrelated repo.

**Fix:** Change to `github:DarthPJB/nixinate`.

---

## Warnings

### W1: Size parsing regex bug for multi-character suffixes

**Location:** Step 5.1, Prompt

**Problem:** The suffix parsing uses:
```nix
suffix = builtins.head (builtins.match "[0-9]+(.)" str);
```

The regex `[0-9]+(.)` captures only a **single character** after the digits. For `imageSize = "20GB"`, `suffix` would be `"GB"` (captured by the `(.*)` pattern in the num regex), but the suffix check uses `suffix == "G"` which would be false for `"GB"`.

The current defaults all use single-character suffixes ("20G", "1024M", "8G"), so this won't bite in the happy path. But if a user specifies `imageSize = "1GB"`, the parsing would fail and default to a very small size or error out.

This is acceptable for v1 as the plan itself notes future extensions would add format options, but it should be documented as a known limitation.

---

### W2: ISO and QEMU image outputs untested

**Location:** Phase 4

**Problem:** The plan's approach to QEMU (importing `qemu-guest.nix`) and ISO (using `virtualisation.virtualbox.guest.enable = true`) has not been validated against the actual disko+nixosSystem image building pipeline. The QEMU approach using `system.build.images.qemu` via `qemu-guest.nix` is plausible but the disko module may not integrate cleanly with nixpkgs's QEMU image builder. The ISO approach is definitely wrong (see C7).

**Fix:** Phase 4 should include a verification step that actually attempts to build a QEMU and ISO image, not just grep for attribute names.

---

### W3: No verification of actual image builds

**Location:** All verification gates

**Problem:** All verification gates only check for attribute existence or grep for strings in the source. None actually attempt to build an image or validate the generated Nix code end-to-end. For example:
- Phase 2 verification does not check that `diskoImages` is actually a valid attribute on the built config.
- Phase 3 verification does not validate that the installer image can boot in QEMU.
- Phase 5 verification does not actually test that undersized images fail at eval time.

**Fix:** Add a smoke test to at least one verification gate that attempts `nix build .#test-machine-raw-image` with a minimal config and verifies it succeeds (or fails with the expected error message).

---

### W4: Dependency declaration inconsistency

**Location:** Phase 4 header

**Problem:** Phase 4 is tagged as depending on "Phase 2 complete and tagged", but it logically depends on Phase 3 (installer module) as well, since the installer module provides some of the infrastructure (like the auto-dd script) that might be needed. This is not a blocking issue but could cause confusion during execution.

---

## Suggestions

### S1: Phase 1 and Phase 2 could be merged

Steps 1.1, 1.2, 1.3, and 1.4 all touch `flake.nix` or create small module files. Steps 2.1 and 2.2 also modify `flake.nix`. Splitting these across phases adds verification overhead without much benefit. Consider merging Phase 1 and Phase 2 into a single "Foundation + Raw Image" phase with 6 steps.

### S2: Add Step 3.5 for closure size validation in installer

The plan validates image sizes for the raw image (Phase 5) but does not check that the embedded payload (`/install/image.raw.zst`) fits within the installer's image size (`7800M`). If the raw image + installer system exceeds 7800M, the build will fail in a non-obvious way inside the QEMU VM.

**Fix:** Add a step that computes `raw-image-zstd` size and asserts it + installer overhead < installer `imageSize`.

### S3: The `auto-dd-install.sh` reference path is a relative path

**Location:** Step 3.3, Prompt

```nix
text = ''
  export INSTALLER_IMAGE="/install/image.raw.zst"
  ${builtins.readFile ./auto-dd-install.sh}
'';
```

This uses a relative path `./auto-dd-install.sh` which is resolved relative to the Nix store path where the shell script is written, not relative to the source file. This will fail at build time.

**Fix:** Use an absolute path or `self` reference:
```nix
text = ''
  export INSTALLER_IMAGE="/install/image.raw.zst"
  ${builtins.readFile (self + "/modules/images/auto-dd-install.sh")}
'';
```

Or reference it via `pkgs.writeText` and copy from there.

---

## Verdict: FAIL

The plan cannot be executed as written due to:
1. **C1**: `genImages` stub references non-existent `nixpkgsFor.${system}.generateImages`
2. **C2**: Invalid Nix assert syntax in size validation
3. **C3**: `lib.remove ""` does not exist in nixpkgs lib (should be `lib.filter`)
4. **C4**: `nixpkgs` not in scope inside `mkImagePackages`
5. **C5**: Installer GRUB config missing `efiInstallAsRemovable = true`
6. **C6**: Disko autoinstaller config strategy is unclear and may produce duplicate disk definitions
7. **C7**: ISO output uses wrong `virtualisation.virtualbox.guest` approach
8. **C8**: Example flake references `Bargman-Tech/nixinate` instead of `DarthPJB/nixinate`

Additionally, **W3** (no actual build verification) means that even if the code is generated, there is no confidence it produces working images.

**Recommendation:** Fix all Critical issues (C1-C8) before giving this plan to `bellana-deepseek`. Re-review after fixes are applied.
