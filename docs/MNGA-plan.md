# Make Nixinate Great Again (MNGA) — Implementation Plan

## Philosophy

Nixinate is a production deployment tool, not a proof of concept. It evolved
from a PoC abandoned by its original author into a real-world tool used daily
for three years. The goal is to become the canonical industry application for
NixOS deployment to real production systems.

**Core tenets:**

- **"Just bash and nix"**: The generated scripts are plain bash. The logic is
  pure Nix evaluation. If a C runtime helper is ever needed, it earns its
  place — but the bar is high.
- **Strict deployment matrix**: Nixinate offers a limited, well-defined set of
  deployment methods (local, remote, hermetic, incubation). Each method is
  functional, declarative, dependable, and reliable. The matrix is deliberately
  constrained — users don't pick from twenty options, they pick from a few that
  always work.
- **No timeouts, no masking**: Stalls are errors. Every phase produces visible
  output. If something hangs, the user sees it and decides what to do.
- **Deployed or not deployed**: There is no partial state. A deployment either
  succeeded or it failed. No soft warnings, no ambiguous states.

Three years of daily use have proven this works. Now we're taking it further:
this isn't a PoC anymore, it's the tool the NixOS community will use for real
production deployments. Incubation and imaging will push Nix into data centers,
remote sites, and bare-metal provisioning at scale — places that have never
been reachable before.

## Current State (May 2026)

- Two build paths: `local` (build locally, copy, activate) and `remote` (copy
  flake, build + activate on target)
- Each has a `hermetic` variant that copies Nix itself to the remote
- Local-build path has a visible pre-copy step (added May 2026)
- Hermetic path lacks equivalent visibility
- Debug mode (`debug = true`) adds SSH verbosity, nix verbose, phase banners
- Known bugs: bare `nix` on line 88, `--option builders ''` confusion, SSH
  output truncation via `sem`
- **Architecture clarified May 2026:**
  - The **hermetic payload** (tools shipped to target) is a **user-selectable tool set**, not a deployment of the deployer's nixpkgs
  - `hermetic` is being converted from bool to a set (`enable`, `nixos-rebuild`, `nix`) to support explicit tool selection
  - This enables two documented deployment patterns: **incremental migration** (stepwise stateful upgrades) and **leapfrog** (direct jump from old NixOS to unstable)
  - `nix flake check` integration planned for evaluation-time validation
  - Cross-arch requires exploration and testing before decisions can be made (deferred)

---

## Phase 1: Stabilization

Fix known bugs so the current code works reliably.

### 1.1 — Fix bare `nix` in hermetic activation

**What**: Line 88 of the generated hermetic activation uses bare `nix` instead
of the wrapped `${nix}` binary (which includes `--experimental-features`).

**Acceptance**: Generated deploy script uses the wrapped nix binary consistently.

### 1.2 — Fix `--option builders ''` output confusion

**What**: The `--option builders ''` flag causes `nix copy` to report
"copying 0 paths" even when paths need copying.

**Approach**: Move `--option builders ''` to only the build/realise steps where
it's actually needed. Remove it from `nix copy` commands.

**Acceptance**: `nix copy` output accurately reflects what was transferred.

### 1.3 — Refine debug mode

**What**: When `debug = true`, print the exact composed command for each phase
in a readable format, rather than raw `set -x` trace.

**Acceptance**: `debug = true` output is readable and shows exactly what commands
are being run.

### 1.4 — Fix SSH output truncation from `sem`

**What**: GNU parallel's `sem` causes SSH output to be truncated in the deploy
log. The `[DEPLOY END]` marker often doesn't appear.

**Acceptance**: Deploy log contains complete output including the `[DEPLOY END]`
marker.

### 1.5 — Add heartbeat mechanism for stall detection

**What**: Each long-running phase emits periodic heartbeat output (every 30s).
If a phase hangs, the heartbeat continues, making the stall visible.

**Acceptance**: If a phase hangs, the log shows heartbeat output indicating the
phase is still running.

---

## Phase 2: Hermetic Parity

Bring the hermetic path to the same visibility as the local-build path.

### 2.1 — Add phase markers to hermetic path

**What**: The hermetic path should have the same `=== [PHASE START/END]`
markers as the local-build path.

**Markers**: `[FLAKE COPY]`, `[DERIVATION COPY]`, `[ACTIVATION]`

**Acceptance**: Hermetic deploy log shows complete phase progression with
timestamps.

### 2.2 — Add pre-copy to hermetic path

**What**: Before running `nixos-rebuild` on the remote, pre-copy the system
closure so the remote build can find it immediately.

**Acceptance**: Hermetic deploy shows visible progress during closure transfer.

### 2.3 — Update README hermetic documentation

**Acceptance**: README accurately describes the hermetic pipeline.

### 2.4 — Convert `hermetic` from bool to tool selection set

**What**: `hermetic` becomes a set with fields for tool selection, not a
boolean toggle. Users can specify which `nixos-rebuild` and `nix` packages
ship to the target.

**Schema**:
```nix
_module.args.nixinate.hermetic = {
  enable = true;
  nixos-rebuild = <package>;   # optional, defaults to deployer's
  nix = <package>;              # optional, defaults to deployer's
};
```

**Default behavior**: When `hermetic = true` (legacy bool, accepted for
backward compatibility) or omitted entirely, behavior matches current
defaults — deployer's `nixos-rebuild` ships to the target.

**Acceptance**: Existing configurations with `hermetic = true` continue
to work. New configurations can select specific tool versions.

### 2.5 — Document incremental migration and leapfrog patterns

**What**: The tool selection model enables two critical workflows that
must be documented as first-class deployment patterns.

**Incremental migration** — pin the hermetic payload to an older nixpkgs
revision matching the target's current version, for stepwise stateful
upgrades:

```nix
oldPkgs = import nixpkgs { system = "x86_64-linux"; rev = "21.11"; };
_module.args.nixinate.hermetic.nixos-rebuild = oldPkgs.nixos-rebuild;
```

**Leapfrog upgrade** — ship the latest rebuild engine (ng, or any
version) directly to an ancient NixOS target:

```nix
latestPkgs = import nixpkgs { system = "x86_64-linux"; };
_module.args.nixinate.hermetic.nixos-rebuild = latestPkgs.nixos-rebuild-ng;
```

**Acceptance**: Both patterns appear in README, MNGA plan, and reference
documentation with configuration examples and when-to-use guidance.

---

## Phase 3: MNGA Core

Make hermetic the primary strategy with robust error detection.

### 3.1 — Make hermetic the default

**What**: Hermetic is default for same-arch. Non-hermetic is opt-out.

**Acceptance**: `nix run .#myMachine` uses hermetic by default on same-arch.

### 3.2 — Explicit cross-arch policy

**What**: Cross-arch without explicit `hermetic = true/false` produces a hard
error. No soft warnings.

**Acceptance**: Cross-arch deployment is either explicitly supported or fails
with a clear error.

### 3.3 — Legacy-safe rebuild engine

**What**: Hermetic pipeline works on NixOS 21.11+ where `nixos-rebuild-ng`
may not be available. The hermetic payload is **user-selectable** — the
deployer can ship classic `nixos-rebuild`, `nixos-rebuild-ng`, or any
custom rebuild tool. The default must be compatible with legacy targets.

**Context separation**: ng modernization applies to the **deployer side**
(`nix build`, `nix copy`, preflight checks). The **hermetic payload**
must remain compatible with classic `nixos-rebuild` on NixOS 21.11+.
These are separate concerns — deploying to legacy targets is **the
feature**, not a compatibility burden.

**Acceptance**: Deploy to a NixOS 21.11 remote succeeds via hermetic mode
using either the default rebuild engine or a user-selected engine.

### 3.4 — `nix flake check` integration

**What**: Generate `checks` outputs alongside deploy apps for
evaluation-time validation of nixinate configuration. Gated by
`check = true` (default).

**Checks include**:
- Required field presence and type correctness
- SSH key paths exist at evaluation time
- Port format, buildOn value, hermetic config consistency
- Selected nixos-rebuild package validity

**Acceptance**: `nix flake check` catches misconfigured nixinate settings
before any deployment begins.

---

## Phase 4: Incubation Deployments

Deploy to non-Nix systems. This is the logical evolution of hermetic mode.

Hermetic deployments are the first step toward incubation. With hermetic, we
copy Nix to a NixOS system. Incubation extends this concept: we copy the
entire nix-store to a **non-Nix** Linux system and then execute a "copy then
install" workflow to bootstrap it.

### Concept

An incubation deployment takes an existing SSH connection to a **non-Nix Linux
system** and copies a nix-store into place, then rebuilds — **without requiring
a nix-daemon on the target**.

This is the "sneaky but absolute" tool: virtually any Linux system with a
root-level SSH user becomes a deployment target, provided the configuration is
correct.

### How it works

1. **Bootstrap**: SSH into the target as root. Detect the system state (disk
   layout, existing init, package manager).
2. **Store injection**: Copy a pre-built nix store (containing nix, nixos-rebuild,
   and the system closure) to the target via SSH. No nix-daemon needed — just
   `scp`/`rsync` of store paths.
3. **Install**: Using the injected nix store, run the incubation installer
   (not rebuild-switch) to activate the NixOS configuration. This "copy then
   install" approach is distinct from hermetic's "copy then rebuild" — it
   handles partition discovery, bootloader setup, and init replacement on
   non-Nix systems.
4. **Verify**: Confirm the system rebooted into NixOS and is reachable.

### Implementation

- **New parameter**: `buildOn = "incubation"` (or `deploy = "incubation"`)
- **Pre-requisite**: Root SSH access to a Linux system with `bash`, `tar`, and
  enough disk space for the nix store
- **Store format**: A zstd-compressed tar of the minimal nix store, transferred
  via SSH and extracted on the target
- **No nix-daemon**: The injected store includes a standalone `nix` binary that
  operates in single-user mode
- **Rollback**: The original system state is preserved (e.g., GRUB entry to
  boot the old system)

### Acceptance

- Deploy to a bare Ubuntu/Debian/Fedora system with only root SSH access
- Target ends up running the NixOS configuration
- Original system is recoverable via GRUB

---

## Phase 5: Image and Installer Outputs

Enable offline deployment via pre-built images.

### 5.1 — Image output

**What**: A `nixosImage` output that produces a minimal NixOS disk image
(raw or qcow2) containing the system closure.

**Format**: zstd-compressed raw image (smallest, fastest to write)

**Output**: `apps.x86_64-linux.image-myMachine` — produces the image file

**Acceptance**: `nix run .#image-myMachine` produces a bootable disk image.

### 5.2 — Installer output

**What**: A `nixosInstaller` output that takes the image as a payload and
produces an installer script. When run on a target machine, it:

1. Identifies the target disk/partition
2. Writes the image using `dd` (with progress)
3. Resizes the partition table and filesystem to match the target disk
4. Installs GRUB (or systemd-boot) to make the image bootable

**Output**: `apps.x86_64-linux.installer-myMachine` — produces the installer

**Two modes**:
- **From-image**: The installer carries the zstd image as an embedded payload
  (self-contained, no network needed)
- **From-store**: The installer pulls from a local nix store or binary cache
  (smaller installer, requires network or local store)

### 5.3 — Insert-and-reboot deployment

**What**: The combination of image + installer enables fully offline automated
installation:

1. Build the installer: `nix run .#installer-myMachine`
2. Transfer the installer USB/script to the site (no internet required)
3. Boot the target from the installer media (or run the script)
4. The installer writes the NixOS image to the target disk
5. Reboot — the target is now running NixOS

**This works with NO REQUIRED INTERNET ON SITE.** The image is self-contained.
The installer is self-contained. The entire deployment happens offline. This is
a sneaky but absolute game-changer for air-gapped sites and remote
deployments — truly a VERY valuable capability for the Nix ecosystem.

**Use cases**:
- Air-gapped data centers
- Remote sites with no connectivity
- Bare-metal provisioning at scale
- Pre-imaged NVMe drives ("insert and reboot")

### Acceptance

- `nix run .#installer-myMachine` produces a self-contained installer
- The installer writes a bootable NixOS image to a bare disk
- The process works with zero network connectivity
- Partition resize works for disks larger than the image

---

## Phase 6: Ecosystem

Community readiness, cross-arch, and advanced features.

### 6.1 — Legacy system validation

Test hermetic and incubation deployments against NixOS 21.11, 23.05, 24.05,
and bare Ubuntu/Debian/Fedora systems.

### 6.2 — Cross-arch hermetic support

Implement full hermetic cross-arch by copying the correct platform's nix binary
and using binfmt/emulation where needed.

### 6.3 — Community-grade documentation

- Supported matrix (local/remote/hermetic/incubation × arch)
- Troubleshooting section mapped to phase logs
- Legacy upgrade guide
- Incubation deployment guide
- Image/installer usage guide

### 6.4 — Smoke tests

Add lightweight scripts that exercise:
- Phase ordering
- Failure propagation
- Heartbeat/stall behavior
- Image build and write
- Incubation to bare system

---

## Deployment Matrix (Target State)

| Method | Requires Nix on target | Requires nix-daemon | Network | Use case |
|--------|----------------------|-------------------|---------|----------|
| `local` | Yes | Yes | SSH | Standard NixOS-to-NixOS |
| `remote` | Yes | Yes | SSH | Remote build, limited deployer |
| `hermetic` | No (copies Nix) | Yes (via copy) | SSH | Deterministic, legacy NixOS |
| `incubation` | No | No | SSH | Any Linux, bare metal |
| `image` | No | No | None | Offline provisioning |
| `installer` | No | No | None | Insert-and-reboot |

---

## Decisions (May 2026)

1. **Cross-arch policy**: No soft warnings. Hard success or hard failure.
   Cross-arch deferred — requires exploration and testing before decision.
2. **Heartbeat interval**: 30s for now. Long-term: animated ASCII progress bar
   with time estimates and copy speed.
3. **Lock mechanism**: Keep `sem` (GNU parallel). Migrated away from `flock`
   previously. Fits GNU protocols.
4. **Hermetic cross-arch**: Deferred. Needs exploration and testing before
   any implementation decision can be made.
5. **Incubation**: Root SSH access is the only hard requirement. No nix-daemon,
   no NixOS prerequisites.
6. **Images**: zstd-compressed raw images. Self-contained. No network required.
7. **Hermetic tool selection model**: `hermetic` becomes a set (`enable`,
   `nixos-rebuild`, `nix`), not a bool. Default behavior preserves current
   semantics for backward compatibility. Enables incremental migration and
   leapfrog upgrade patterns.
8. **ng is deployer-side only**: The hermetic payload is a user-selectable tool
   set, not a deployment of the deployer's nixpkgs. ng modernization applies
   to deployer-local operations. The hermetic payload must remain compatible
   with classic `nixos-rebuild` on legacy NixOS 21.11+ targets.
9. **`nix flake check` integration**: Planned. Generates `checks` outputs for
   evaluation-time validation of nixinate configuration (optional, default-on).
