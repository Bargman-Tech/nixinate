# Re-Review: tpol-xai (Architecture)

## Previous Concerns Addressed?

Yes — all five key changes directly resolve the prior architectural findings:

1. **Raw images from existing nixosConfiguration**: The plan now explicitly reads `flake.nixosConfigurations.${machine}.config.system.build.diskoImages` (Step 2.1). No derived `nixosSystem` is created for raw output. The user's config is responsible for importing `nixinate.nixosModules.image-gen` + disko (documented in example and README).

2. **Only installer uses separate nixosSystem**: Installer is correctly treated as a distinct minimal system (Step 3.4). It uses `final.lib.nixosSystem` with installer-specific modules (installer.nix, auto-dd.nix) and its own disko schema ("autoinstaller" disk key). Raw/QEMU continue to read from the user's evaluated config.

3. **Disko defaults use lib.mkDefault**: The default schema module (Step 1.4) applies `lib.mkDefault` to the entire `disko.devices.disk.main` attrset. No `mkIf (config.disko.devices == {})` or brittle equality checks remain.

4. **ISO uses installercd.nix**: Step 4.1 correctly references `"${final.path}/nixos/modules/profiles/installercd.nix"` and explicitly notes "Do NOT use virtualisation.virtualbox.guest.enable."

5. **Nix syntax fixes**:
   - `assert sizeValid; <expr>` (not parenthesized) — Step 5.2
   - `final.lib.filter` + `final.lib.forEach` (not `lib.remove`) — Steps 1.2, 2.1
   - `final.lib.nixosSystem` (not `nixpkgs.lib.nixosSystem`) inside overlay — Steps 3.4, 4.1

Additional fixes (writeShellApplication, example URL, auto-dd re-run semantics) are also present.

## Remaining Concerns

None. The revised architecture cleanly separates "user's system" from "installer system" and uses the module system correctly for defaults.

## New Concerns (if any)

None. The plan is now internally consistent and respects NixOS module evaluation order.

## Verdict: PASS
