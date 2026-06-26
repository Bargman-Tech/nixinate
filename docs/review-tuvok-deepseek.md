# Adversarial Review: tuvok-deepseek (Failure Mode Analysis)

## Summary

This review examines the image generation action plan for the nixinate project. The plan implements disk image and installer generation using disko, with auto-installation via dd. The architecture appears sound but contains several critical failure modes that must be addressed before implementation.

## Critical Failure Modes

### 1. Auto-DD Script Will Fail on Generic Hardware

**Problem:** The reference auto-dd-install.sh script assumes `/dev/nvme0n1` as the target device. In the action plan (Step 3.2), it mentions adapting to be generic with `INSTALL_TARGET` env var, but there's no mechanism to set this at runtime.

**Consequence:** The installer will fail on systems without NVMe drives (e.g., SATA SSDs `/dev/sda`, older systems with HDDs).

**Evidence:** 
- Reference script hardcodes `TARGET="/dev/nvme0n1"` (line 37)
- Plan mentions `INSTALL_TARGET` env var but no provisioning mechanism
- No fallback detection or user interface for device selection

**Mitigation Required:** Must implement either:
- Automatic detection of largest internal non-removable disk
- Kernel command-line parameter (`nixos.install.target=/dev/sda`)
- Interactive menu with safety warnings

### 2. Race Condition in Systemd Service

**Problem:** The systemd service (`auto-dd-install`) is triggered by `multi-user.target`. If the system boots multiple times (power interruption, user reboot), the service will re-run and destroy the newly installed system.

**Consequence:** User installs system, reboots, installer runs again and overwrites fresh installation.

**Evidence:**
- Service `wantedBy = [ "multi-user.target" ]` (plan Step 3.3, line 511)
- Service `RemainAfterExit = true` means it persists across reboots
- No mechanism to disable service after successful run

**Mitigation Required:** Must implement:
- Success marker file (`/etc/install-success`) to prevent re-runs
- Service should disable itself after successful execution
- Alternative: Run only on first boot via `first-boot.target`

### 3. DD Operation Can Corrupt Target Disk Unexpectedly

**Problem:** The `dd` operation uses `bs=4M` without verifying the target disk supports this block size. Some hardware (especially USB controllers) may fail with large block sizes.

**Consequence:** Partial write, corrupted partition table, unbootable system.

**Evidence:**
- Reference script uses `dd of="$TARGET" bs=4M` (line 146)
- No fallback to smaller block sizes on write errors
- No verification of successful write beyond `dd` exit code

**Additional Risk:** The `conv=fsync` flag mentioned in plan (Step us 3.2, line 457) but missing from reference script.

**Mitigation Required:**
- Implement retry logic with decreasing block sizes
- Add `conv=fsync` flag as documented
- Post-write verification (compare checksums)

### 4. Installer Image Larger Than Target Disk

**Problem:** The plan calculates `rootSizeBytes = imageSizeBytes - espSizeBytes - swapSizeBytes` (Step 5.2, line 807) but doesn't compare against actual target disk size.

**Consequence:** User builds 64GB installer image, tries to install on 32GB disk, fails with cryptic out-of-space errors.

**Evidence:**
- Size validation only checks `rootSizeBytes > 0` (Step 5.2, line 810)
- No comparison against `INSTALL_MIN_DISK_GB` (64GB default)
- Installer script checks disk size but can't prevent build

**Mitigation Required:** 
- Build-time check: `imageSize <= minDiskSize`
- Clear error: "Image requires XGB, target disk has YGB"
- Dynamic sizing option for small disks

### 5. Disko Schema Conflicts with User's Existing Schema

**Problem:** The plan adds default disko schema when `config.disko.devices == {}` (Step 1.4, line 180). However, users may have partial disko schemas that conflict.

**Consequence:** User defines `disko.devices.disk.main` but not other required partitions, gets merge errors or incorrect layout.

**Evidence:**
- Condition `mkIf (config.disko.devices == {})` is brittle
- Users may define some but not all disk devices
- Merge semantics unclear when mixing user and default schemas

**Mitigation Required:**
- Better detection: check if `disko.devices.disk.main` exists
- Schema validation to ensure completeness
- Clear error messages for conflicting definitions

### 6. Disko Image Builder Output Format Changes

**Problem:** The plan assumes `config.system.build.diskoImages` returns `/installer.raw` (Step 3.4, line 595). Disko could change this output structure.

**Consequence:** Build breaks when disko updates, installer fails to find image.

**Evidence:**
- Hardcoded `cp autoinstaller.raw "$out/installer.raw"` (Step 3.4)
- Assumes specific output structure
- No version compatibility checking

**Mitigation Required:**
- Use disko's public API: `config.system.build.diskoImages.installer.raw`
- Version pinning in flake.nix
- Graceful degradation with clear errors

### 7. Nix Evaluation Infinite Recursion Risks

**Problem:** The derived configs import modules that reference themselves through `_module.args.nixinate` (Step 2.1, line 298).

**Consequence:** Infinite recursion when evaluating `nixinate` attribute within derived config.

**Evidence:**
- Derived config imports `{ _module.args.nixinate = userConfig._module.args.nixinate; }`
- This creates circular reference if derived config tries to access its own `nixinate` images config
- Nix evaluation may hang or produce cryptic errors

**Mitigation Required:**
- Isolate derived configs from original `nixinate` config
- Extract only needed values (image sizes) not entire structure
- Break circular dependency

### 8. Multiple Machines with Different Architectures

**Problem:** The `genImages` function uses `system = userConfig.config.nixpkgs.hostPlatform.system` (Step 2.1, line 289). Cross-architecture builds require binfmt but aren't addressed.

**Consequence:** Cannot build `aarch64-linux` images on `x86_64-linux` host without explicit binfmt setup.

**Evidence:**
- No mention of `nixpkgs.crossSystem` or binfmt configuration
- `forAllSystems` in flake.nix doesn't handle cross-compilation
- Existing nixinate handles cross-arch deployment but not images

**Mitigation Required:**
- Support cross-architecture image building via binfmt
- Clear documentation on requirements
- Fallback to emulation if binfmt unavailable

## Security Concerns

### 1. Unauthenticated Device Overwrite (Violates Prime Directive 1: Human Safety First)

**Problem:** The installer automatically overwrites `$TARGET` without requiring authentication beyond booting the installer.

**Consequence:** Malicious actor can boot installer USB, overwrite any attached disk. This violates the "Human Safety First" directive by allowing destruction of user data without consent.

**Evidence:**
- No password or confirmation required
- Service starts automatically on boot
- Only safety check is "not current root disk"
- Violates Prime Directive 1: "Never take actions that could harm humans, their data, their environment"

**Mitigation:** 
- Add mandatory confirmation (key press, password) for production use
- Implement consent verification similar to `sudo` authentication
- Create safety interlock requiring explicit user action

### 2. Kernel Command Line Injection

**Problem:** Plan mentions future kernel cmdline override (plan page 381) but v1 has no validation.

**Consequence:** User passes `nixos.install.target=/dev/sda1` (partition not disk), script fails or corrupts partition. Could be exploited for privilege escalation.

**Evidence:** No parameter validation in reference script.

**Mitigation:** Validate target is whole disk device (`/dev/sdX`, `/dev/nvmeXnY`) not partition. Use `lib.getExe` pattern as required by Prime Directive 19.

### 3. Environment Variable Injection

**Problem:** `INSTALL_TARGET`, `INSTALL_MIN_DISK_GB` env vars could contain malicious values.

**Consequence:** Shell injection via `$TARGET` in `dd` command. Violates Prime Directive 7 (File Operation Integrity) by allowing untrusted input.

**Evidence:** Script uses `"$TARGET"` quoting but not all variables are properly sanitized.

**Mitigation:** 
- Strict validation of env vars before use
- Use Nix's type system to validate sizes (Prime Directive 18: `writeShellApplication`)
- Implement input sanitization following `set -euo pipefail` requirements

### 4. Missing Write Verification (Data Integrity Violation)

**Problem:** Plan acknowledges "No write verification" as deferred concern (plan page 422).

**Consequence:** Silent corruption during write goes undetected, violating data integrity principles.

**Evidence:** Reference script lacks `cmp` or checksum verification.

**Mitigation:** Implement `dd ... && cmp` or SHA256 verification.

### 5. Violation of Nix Declarative Principles (Prime Directive 20)

**Problem:** The auto-install script performs imperative operations (`dd`, `sgdisk`, `growpart`) rather than declarative configuration.

**Consequence:** Breaks NixOS reproducibility principle. Installation is stateful operation not captured in Nix store.

**Evidence:** Script runs shell commands directly rather than generating declarative configuration.

**Mitigation:** Consider using disko's declarative install mechanisms instead of imperative shell script.

### 6. Insufficient Error Handling (Violates Prime Directive这种行为)

**Problem:** Script uses `set -euo pipefail` but doesn't implement comprehensive error recovery.

**Consequence:** Partial failures leave system in undefined state, violating operational integrity.

**Evidence:** Error handling limited to `exit 1` without cleanup or recovery.

**Mitigation:** Implement transactional approach with rollback capabilities.

### 7. Cloud Provider Usage Risk (Violates Prime Directive 8)

**Problem:** While not directly using cloud providers, the installer could be used to provision cloud VMs.

**Consequence:** Potential violation of "Baremetal Nix Primacy" directive if used for cloud deployment.

**Evidence:** No restrictions on deployment target environment.

**Mitigation:** Document intended baremetal use case only.

## Edge Cases

### 1. USB 2.0 vs USB 3.0 Install Media

**Problem:** Installer image may be larger than available RAM on systems booting from USB 2.0 media.

**Consequence:** `zstd -d -c` pipeline buffers exceed available memory, OOM kill.

**Evidence:** No memory pressure management in dd pipeline.

**Mitigation:** Use `pv` or `mbuffer` to control buffer sizes.

### 2. UEFI vs Legacy BIOS

**Problem:** Default disko schema assumes UEFI (ESP partition). Legacy BIOS systems won't boot.

**Consequence:** Installed system unbootable on older hardware.

**Evidence:** Schema hardcodes `type = "EF00"` for ESP.

**Mitigation:** Detect firmware type or provide BIOS-compatible schema option.

### 3. Disk With Existing RAID/LVM/Docker

**Problem:** Target disk may have software RAID, LVM, or Docker pools that `lsblk` doesn't fully reveal.

**Consequence:** Installer destroys hidden data structures, data loss.

**Evidence:** Safety checks only examine mounted filesystems.

**Mitigation:** Check for `mdadm`, `lvs`, `docker info` before proceeding.

### 4. Power Loss During Install

**Problem:** No transaction safety or resume capability.

**Consequence:** Partial write leaves disk in inconsistent state, unrecoverable.

**Evidence:** No checkpointing or resume mechanism.

**Mitigation:** Implement two-stage install with recovery partition.

### 5. Filesystem-Specific Assumptions

**Problem:** Assumes `ext4` for root, `vfat` for ESP. Users may want `btrfs`, `xfs`, `zfs`.

**Consequence:** Cannot use preferred filesystems.

**Evidence:** Schema hardcodes `format = "ext4"` and `format = "vfat"`.

**Mitigation:** Make filesystem types configurable.

### 6. Swap Partition Size vs System RAM

**Problem:** Fixed `swapSize = "8G"` may be inappropriate for systems with 128GB RAM or 2GB RAM.

**Consequence:** Poor performance or wasted space.

**Evidence:** No dynamic sizing based on RAM.

**Mitigation:** `swapSize = "size('8G') max(ramSize/2)` heuristic.

### 7. GPT on Small Disks (<2TB)

**Problem:** GPT requires 34 sectors overhead, may be problematic on tiny disks.

**Consequence:** Wasted space on small embedded systems.

**Evidence:** Always uses GPT, no MBR option.

**Mitigation:** Use MBR for disks <2TB unless UEFI required.

### 8. Concurrent Installation Attempts

**Problem:** Multiple installer USBs booted simultaneously could race.

**Consequence:** Corrupted writes, undefined behavior.

**Evidence:** No locking mechanism across instances.

**Mitigation:** File locking on target disk.

## Critical Safety Alert: Systemd Service Creates Data Destruction Loop

**Immediate Safety Hazard:** The current design where `auto-dd-install` service runs on every boot to `multi-user.target` creates an **automatic data destruction vulnerability**.

**Scenario:**
1. User boots installer USB, installs system to disk
2. System reboots (power cycle, accidental reboot, etc.)
3. BIOS/UEFI still boots from USB (common default behavior)
4. Installer system boots again (USB still present)
5. **Service runs again, overwriting the freshly installed system**
6. All user data destroyed, system returns to installer state

**Violates Prime Directive 1 (Human Safety First):** Creates automated mechanism for data destruction without user consent or awareness.

**Required Fixes:**
- Service must run only once via `first-boot.target`, not `multi-user.target`
- Success marker file (`/etc/nixinate-installed`) must prevent re-execution
- Service must disable itself after successful run: `systemctl disable auto-dd-install`
- Clear visual indication that installation completed and system should be rebooted without USB

## Verdict: CONDITIONAL PASS

The image generation plan is architecturally sound but contains **critical, show-stopping issues** that must be addressed before implementation. Additionally, several aspects **violate Core Prime Directives** and require remediation.

### Prime Directive Compliance Issues:

1. **Violates Directive 1 (Human Safety First)**: Unauthenticated disk overwrite allows data destruction without consent.

2. **Violates Directive 7 (File Operation Integrity)**: Insufficient validation of environment variables and user input.

3. **Violates Directive 18 (writeShellApplication)**: Plan doesn't specify using `writeShellApplication` with explicit `runtimeInputs`.

4. **Violates Directive 19 (lib.getExe)**: Shell script examples don't use `lib.getExe` for tool invocations.

5. **Violates Directive 20 (Nix Is Declarative)**: Imperative installation script contradicts Nix declarative philosophy.

### Must Fix Before Implementation:
1. **Auto-DD device selection** - Cannot hardcode `/dev/nvme0n1`
2. **Systemd service re-run prevention** - Will destroy fresh installs  
3. **Disko schema conflict handling** - Fragile detection logic
4. **Nix evaluation recursion** - Circular dependency risk
5. **Prime Directive compliance** - Address violations listed above

### Should Fix Before Release:
1. **DD block size fallback** - Hardware compatibility
2. **Write verification** - Data integrity
3. **Image vs disk size validation** - User experience
4. **Cross-architecture support** - Platform coverage

### Nice to Have for v1:
1. **Filesystem flexibility** - Support btrfs/zfs
2. **Dynamic swap sizing** - RAM-based heuristic
3. **BIOS compatibility** - Legacy system support
4. **Power loss resilience** - Transaction safety

### Specific Remediation Examples for Prime Directive Compliance:

**For Directive 18 (writeShellApplication):**
```nix
# WRONG in current plan:
pkgs.writeShellScriptBin "auto-dd-install" '' ... ''

# CORRECT:
pkgs.writeShellApplication {
  name = "auto-dd-install";
  runtimeInputs = with pkgs; [
    util-linux cloud-utils parted e2fsprogs 
    zstd coreutils gptfdisk gawk gnugrep 
    gnused findutils systemd
  ];
  text = '' ... '';
}
```

**For Directive 19 (lib.getExe):**
```nix
# WRONG in reference script:
text = ''
  dd of="$TARGET" bs=4M
  sgdisk -e "$TARGET"
  growpart "$TARGET" 2
''

# CORRECT:
text = ''
  ${lib.getExe pkgs.coreutils} dd of="$TARGET" bs=4M
  ${lib.getExe pkgs.gptfdisk} sgdisk -e "$TARGET"
  ${lib.getExe pkgs.cloud-utils} growpart "$TARGET" 2
''
```

**For Directive 20 (Nix Declarative):**
```nix
# Consider using disko's declarative install instead:
config.system.build.installerScript = pkgs.writeShellApplication {
  name = "declarative-install";
  runtimeInputs = [ config.system.build.diskoImages ];
  text = ''
    # Use disko's nix-based installation
    ${config.system.build.diskoImages}/bin/disko-install
  '';
};
```

### Testing Methodology for This Review:

This adversarial review applied the following testing perspectives:

1. **Hardware Compatibility Testing**: Evaluated assumptions about `/dev/nvme0n1`, block sizes, firmware types
2. **Failure Mode Analysis**: Identified race conditions, corruption scenarios, edge cases  
3. **Security Testing**: Analyzed authentication, injection vulnerabilities, data integrity
4. **Prime Directive Compliance**: Checked alignment with Core Prime Directives 1-21
5. **Nix Best Practices**: Validated against Nix declarative principles and tool usage patterns
6. **User Experience Testing**: Considered realistic deployment scenarios and failure modes

**Review Limitations:**
- Based on documentation analysis only, not code execution
- Assumes reference implementation accurately reflects planned implementation
- Does not test actual Nix evaluation or build processes

**Next Steps Required:**
1. Implement fixes for critical safety issues before any code changes
2. Revise action plan with safety interlocks and Prime Directive compliance
3. Create test harness to validate fixes before deployment
4. Conduct code review of implementation against this report
```

2. **Revise Action Plan**
   - Add safety and validation steps to each phase
   - Include cross-architecture testing
   - Add rollback/recovery procedures
   - Ensure `writeShellApplication` and `lib.getExe` usage

3. **Testing Strategy**
   - QEMU test harness with varied hardware profiles
   - Power interruption simulation
   - Concurrency and edge case testing
   - Prime Directive compliance verification

The plan demonstrates good understanding of disko capabilities but underestimates real-world deployment complexity and Prime Directive requirements. With the critical fixes implemented, this could be a robust solution. Without them, it risks data loss, user frustration, and directive violations.