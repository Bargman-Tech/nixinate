# Nixinate

Created by Matthew Croughan, who constantly strives for a better path.

Nixinate generates deployment scripts for your NixOS flake's `nixosConfigurations`. Each machine gets a script you can run with `nix run .#machineName`, giving you a fully self-contained deployment pipeline with visible progress at every stage.

## What You Get

When you add nixinate to your flake, you get:

- **One command per machine**: `nix run .#machineName` (or `nix run .#machineName -- switch` to persist)
- **Two build strategies**: build locally or on the remote, choose what suits your infrastructure
- **Hermetic deployment**: copy your Nix binary to the remote for deterministic evaluation (critical for legacy upgrades)
- **Visible pipeline**: timestamped phase markers show exactly where the deploy is at every moment
- **Progress tracking**: interruptions are resumable, stalls surface immediately (no silent hangs)

## Quick Start

1. Add nixinate to your flake inputs:

```nix
{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    nixinate = { 
      url = "github:DarthPJB/nixinate"; 
      inputs.nixpkgs.follows = "nixpkgs"; 
    };
  };

  outputs = { self, nixpkgs, nixinate }: {
    apps = nixinate.lib.genDeploy.x86_64-linux self;

    nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        {
          _module.args.nixinate = {
            host = "10.0.0.1";
            sshUser = "deploy";
          };
        }
      ];
    };
  };
}
```

2. Deploy your machine:

```bash
nix run .#myMachine
```

The default action is `test`—it builds and activates the configuration without persisting across reboot. To switch permanently:

```bash
nix run .#myMachine -- switch
```

## Configuration Reference

All nixinate options live in `_module.args.nixinate` of your `nixosConfiguration`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `host` | string | **required** | SSH hostname or IP address of the target machine |
| `sshUser` | string | **required** | SSH username for authentication on the remote |
| `port` | string | `"22"` | SSH port on the remote machine |
| `buildOn` | `"local"` \| `"remote"` | `"local"` | Where to build the system closure (see Build Modes below) |
| `hermetic` | bool or set | `true` (if same architecture) | Enable hermetic deployment. Boolean for simple on/off, or a set with `enable`, `nixos-rebuild`, `nix` fields for tool selection (see Hermetic Mode below) |
| `substituteOnTarget` | bool | `false` | Use the remote's binary cache during local builds (local-build mode only) |
| `debug` | bool | `false` | Enable SSH verbosity, nix verbose output, and timestamped phase banners |
| `nixOptions` | list of strings | `[]` | Extra flags passed to all nix commands (e.g., `["--max-jobs" "2"]`) |

## Build Modes

### Local Build (buildOn = "local", default)

Builds the system closure on your machine, copies it to the remote, and activates it there. Best when:
- Your deployer machine is powerful
- The target is resource-constrained
- Network bandwidth to the target is good

Pipeline:
```
[PRE-COPY START]  Building and copying system closure to remote
  $ nix build --print-out-paths <flake>#nixosConfigurations.X.config.system.build.toplevel
  $ nix copy <closure> --to ssh://user@host
[PRE-COPY END]

[DEPLOY START]    Activating configuration on remote
  $ nixos-rebuild test --flake <flake> --target-host user@host --sudo
[DEPLOY END]
```

### Remote Build (buildOn = "remote")

Copies the flake source to the remote and builds entirely there. Best when:
- The target machine is powerful
- Network bandwidth to the target is limited
- You want the target to evaluate with its own nix version (non-hermetic)

Pipeline:
```
[COPY START]      Sending flake to remote
  $ nix copy <flake> --to ssh://user@host
[COPY END]

[CLOSE COPY START] Copying nixos-rebuild and tool derivations
  $ nix copy --derivation nixos-rebuild --derivation sem --to ssh://user@host
[CLOSE COPY END]

[ACTIVATION START] Building and activating on remote
  $ ssh user@host "sudo nixos-rebuild test --flake <flake>"
[ACTIVATION END]
```

## Hermetic Mode

When hermetic mode is enabled, nixinate copies your Nix binary and rebuild engine to the remote before running `nixos-rebuild`. This ensures the remote evaluates your flake with the same tools you're running, regardless of what's installed on the target.

**Why hermetic mode matters:**

- **Legacy upgrades**: Deploy to NixOS 21.11+ systems where the installed Nix is too old for modern flake evaluation
- **Deterministic evaluation**: Eliminate environment-specific evaluation differences
- **Self-contained**: The deployer brings everything needed; no assumptions about the remote's Nix version
- **Reproducible**: Same flake input evaluation everywhere

**When it's enabled:**

- **By default** for same-architecture deployments (deployer and target are the same CPU architecture)
- **Never** for cross-architecture deployments (see note below)

### Hermetic Configuration

`hermetic` can be configured as a boolean (simple on/off) or as a set (full tool selection).

**Simple form** (backward compatible):
```nix
_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  hermetic = true;   # or false to disable
};
```

**Tool selection form** (recommended for advanced workflows):
```nix
_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  hermetic = {
    enable = true;
    # Rebuild engine to ship to target (optional, defaults to deployer's nixos-rebuild)
    nixos-rebuild = pkgs.nixos-rebuild;
    # Nix binary to ship (optional, defaults to deployer's nix)
    nix = pkgs.nix;
  };
};
```

The tool selection form lets you ship **specific versions** of `nixos-rebuild` and `nix` to the target, decoupled from the deployer's own nixpkgs. This enables two powerful workflows:

### Deployment Patterns

#### Incremental Migration

Upgrade a machine across NixOS versions **one step at a time**, preserving database and state integrity at each step. Pin the hermetic payload to an older nixpkgs revision matching the target's current version:

```nix
oldPkgs = import nixpkgs {
  system = "x86_64-linux";
  rev = "21.11";  # match target's current nixpkgs
};

_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  hermetic = {
    enable = true;
    nixos-rebuild = oldPkgs.nixos-rebuild;
  };
};
```

Run `nixos-rebuild switch` using the *same* nixpkgs the target is running. Migrate state one step at a time, then repeat with the next version. Use for: database servers, stateful applications, any deployment where a single big leap risks data loss.

#### Leapfrog Upgrade

Jump from an ancient NixOS version (e.g. 21.11) **directly to the latest unstable**, bypassing intermediate releases. Ship the latest rebuild engine as the hermetic payload:

```nix
latestPkgs = import nixpkgs {
  system = "x86_64-linux";
  rev = "nixos-unstable";
};

_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  hermetic = {
    enable = true;
    nixos-rebuild = latestPkgs.nixos-rebuild-ng;
    nix = latestPkgs.nix;
  };
};
```

Use for: machines with no critical state, clean deployments, test systems.

### Disable Hermetic Mode

```nix
_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  hermetic = false;
};
```

Disable if you want the remote to build with its installed Nix version, or you're testing newer Nix features on the target.

### Cross-Architecture Deployments

Cross-architecture deployments (deployer and target on different CPU architectures) are currently under exploration. Hermetic mode is automatically disabled for cross-arch targets until a tested solution is available. See the [MNGA plan](docs/MNGA-plan.md) for the roadmap.

## Debug Mode

Set `debug = true` to see exactly what's happening during deployment:

```nix
_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  debug = true;
};
```

Debug mode enables:
- SSH verbose output (`ssh -vvv`) for connection diagnostics
- Nix verbose output (`nix --verbose`) for copy operations
- Shell command tracing (`set -x`) to see every executed command
- Timestamped phase banners for precise pipeline visibility

Example debug output:
```
=== [PRE-COPY START] 2026-05-24T14:23:01Z Pre-copying system closure to myMachine ===
+ nix copy '/nix/store/...-nixos-system-...' --to ssh://deploy@10.0.0.1
copying /nix/store/... (567 MiB)... [########========] 45%
=== [PRE-COPY END]   2026-05-24T14:24:17Z ===
=== [DEPLOY START] 2026-05-24T14:24:17Z Activating myMachine via nixos-rebuild ===
+ ssh -vvv deploy@10.0.0.1 ...
...
=== [DEPLOY END]   2026-05-24T14:24:42Z ===
```

## Phase Banners

Every deployment shows timestamped phase markers:

```
[PHASE START]  Short description
  $ command that runs...
[PHASE END]
```

These markers let you:
- Track which phase the deploy is in
- Identify where hangs occur (because there are no timeouts)
- Estimate remaining time for long copies
- Resume interrupted deployments from where they left off

## Combining with Other Flake Outputs

If you have other flake apps, merge them with nixinate's:

```nix
outputs = { self, nixpkgs, nixinate }: {
  apps.x86_64-linux = {
    myApp = { type = "app"; program = "${myPackage}/bin/myapp"; };
  } // (nixinate.lib.genDeploy.x86_64-linux self);

  nixosConfigurations = { ... };
};
```

## Design Principles

Nixinate follows these core principles:

- **KISS**: Simple, no unnecessary complexity
- **Visible progress**: Every phase produces timestamped output
- **Stalls are errors**: No timeouts masking real problems
- **Hermetic-first**: Make it work deterministically, then optimize

## MNGA Vision (Make Nixinate Great Again)

Nixinate is evolving from a proof-of-concept into the canonical NixOS
deployment tool for production systems. The philosophy: "just bash and nix" —
minimal, functional, declarative, dependable.

**Current deployment methods:**

| Method | Requires Nix on target | Requires daemon | Network | Use case |
|--------|----------------------|-----------------|---------|----------|
| local | Yes | Yes | SSH | Standard NixOS-to-NixOS |
| remote | Yes | Yes | SSH | Remote build, limited deployer |
| hermetic | No (copies Nix) | Yes (via copy) | SSH | Deterministic, legacy NixOS |

**Coming next:**

- **Incubation**: The sneaky but absolute tool — deploy to any Linux system
  with root SSH access. No Nix, no daemon required. Copy a nix-store into place
  and switch, converting virtually any Linux distro into NixOS.
- **Image**: Minimal bootable NixOS disk image (zstd-compressed raw)
- **Installer**: Self-contained installer that `dd`s the image to a disk,
  resizes partitions, installs bootloader. **Works entirely offline — zero
  internet required.**
- **Insert and reboot**: Pre-imaged NVMe drives for bare-metal provisioning
  at scale. Drop the drive in, reboot, and you're running NixOS. **This is
  VERY valuable for Nix users and should be hyped.**

See [`docs/MNGA-plan.md`](docs/MNGA-plan.md) for the detailed implementation
plan.

This isn't just another deployment tool. It's a fundamental shift in how NixOS
reaches the broader Linux ecosystem. With incubation and image deployment, Nix
users will be able to deploy to literally any Linux system in the world — bare
metal, air-gapped, remote — without requiring a nix-daemon or even Nix on the
target. That's a game-changer.

## Troubleshooting

**Deployment fails with "Nix is too old"**
- Set `hermetic = true` in your nixinate config (default for same-arch)
- This copies the deployer's Nix to the remote

**Remote build hangs or times out**
- Check `debug = true` to see exactly where it's stuck
- Look at the phase banners—"PHASE START" without matching "PHASE END" shows the culprit

**Transfer was interrupted**
- Re-run `nix run .#machineName`
- Interrupted transfers resume from where they left off (not yet—phase 3 of MNGA)

## References

- [NixOS Manual - Flakes](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix-flake.html)
- [NixOS Manual - nixos-rebuild](https://nixos.org/manual/nixos/stable/index.html#sec-changing-system)
- [`docs/MNGA-plan.md`](docs/MNGA-plan.md) — Full roadmap and implementation details
- [`docs/README-legacy.md`](docs/README-legacy.md) — Previous documentation for reference
