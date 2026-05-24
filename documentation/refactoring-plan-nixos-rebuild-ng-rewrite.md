# Nixinate Modernization Refactoring Plan

**Status:** Technical Specification  
**Date:** 2026-05-03  
**Project:** `DarthPJB/nixinate`  
**Consumer Reference:** `DarthPJB/NixOS-Configuration`

## Executive Summary

This plan modernizes nixinate for production-grade safety and `nixos-rebuild-ng` adoption. The work is organized around five critical issue clusters, phased implementation milestones, and explicit exit criteria. Modernization and risk elimination take priority over legacy compatibility.

### Critical Architectural Distinction

Throughout this plan, a sharp distinction must be maintained between two separate contexts:

| Context | Runs on | Purpose | Can use ng? |
|---------|---------|---------|-------------|
| **Deployer-side** | The deployer machine (your workstation, CI) | `nix build`, `nix copy`, preflight checks, schema validation | Yes — modernize freely |
| **Hermetic payload** | The **target** machine (remote NixOS) | The rebuild engine and tools shipped to execute activation | **No — must support legacy NixOS 21.11+** |

The hermetic payload's compatibility with legacy targets is **the feature**, not legacy baggage. `nixos-rebuild-ng` is a deployer-side modernization target. The hermetic payload must remain compatible with classic `nixos-rebuild` and must support **user-selected tool versions** for incremental migration workflows. These are separate concerns and this plan treats them as such.

---

## Critical Issue Clusters

### Cluster A: Rebuild Engine Modernization Blocker ⚠️ **CRITICAL**

**Issue:** The deployment path is hard-coupled to classic `nixos-rebuild` and lacks `nixos-rebuild-ng` detection or integration.

**Evidence:**
- `flake.nix` line 24: `nixos-rebuild` override
- `flake.nix` lines 69, 72, 77: direct command invocation paths

**Impact:** Production deployments are anchored to legacy semantics on the **deployer side**. The deployer's local build/copy commands should be modernized to ng for better diagnostics and structured execution. However, this is distinct from the **hermetic payload** — the tool shipped to the remote target — which must remain compatible with legacy NixOS 21.11+.

**Context separation:**
- **Deployer-side modernization** (ng-first): `nix build`, `nix copy`, preflight checks, schema validation — all deployer-local operations that can adopt ng freely.
- **Hermetic payload** (classic-safe): The rebuild engine shipped to the target must support legacy systems. This is **not** a modernization target — it is a **configurable tool selection** that the user chooses based on their target's capabilities.

The plan must treat these as separate workstreams with separate acceptance criteria.

---

### Cluster B: Unsafe Command Construction ⚠️ **CRITICAL**

**Issue:** Deployment command assembly uses shell string concatenation with interpolated user-configured arguments (`nixOptions`, mode), creating quoting failures and injection vulnerabilities.

**Evidence:**
- `flake.nix` line 50: `concatStringsSep " "`
- `flake.nix` lines 69, 77: embedded command strings with interpolation

**Impact:** Production deployments fail unpredictably under edge cases. String-based composition complicates ng migration and increases maintenance burden.

---

### Cluster C: Missing Preflight Validation ⚠️ **CRITICAL**

**Issue:** The `_module.args.nixinate` contract is only partially validated. Runtime failures occur after expensive steps (host availability, authentication, port availability, tooling assumptions).

**Evidence:**
- `flake.nix` line 39: only `sshUser` is validated
- No explicit preflight phase in generated deploy flow

**Impact:** Failed deployments produce weak diagnostics and waste infrastructure resources. Production operations lack early failure detection.

---

### Cluster D: Cross-Architecture Hermetic Path Known-Broken 🔴 **HIGH**

**Issue:** The hermetic activation path has an acknowledged cross-architecture failure (see `flake.nix` line 69 TODO).

**Evidence:**
- `flake.nix` line 69: TODO comment indicating cross-arch inconsistency

**Impact:** Multi-architecture fleets cannot reliably use this path. Behavior is known-broken under cross-compilation scenarios.

---

### Cluster E: Runtime Dependency and Operational Debt 🔴 **HIGH**

**Issue:** Generated deploy scripts depend on presentation tools (`lolcat`, `figlet`, `parallel/sem`) and use monolithic logic patterns, increasing runtime fragility and hindering portability.

**Evidence:**
- `flake.nix` lines 35–36: cosmetic tooling dependencies
- `flake.nix` line 58: display tools in core path
- `flake.nix` line 85: empty `runtimeInputs` despite cosmetic dependencies

**Impact:** Higher failure surface, poor portability, and difficulty testing. Complicates structured, deterministic execution.

---

## Consumer Compatibility Risks

Analysis of usage patterns in `NixOS-Configuration` surface five risk areas:

| Risk | Severity | Description |
|------|----------|-------------|
| Default mode assumptions | CRITICAL | Existing workflows assume default behavior is safe and test-first |
| CLI pass-through contract | CRITICAL | Common pattern `nix run .#host -- switch` must remain deliberate |
| Remote-build hosts (`buildOn = "remote"`) | CRITICAL/HIGH | These hosts require explicit ng-capable execution paths |
| Legacy CI workflows | HIGH | Build/deploy commands still use legacy invocation patterns |
| Operational log paths | MEDIUM/HIGH | CI may depend on artifact paths and log output shape |

---

## Target Architecture

Adopt a **two-context architecture** that distinguishes between deployer-side operations and the hermetic payload shipped to targets.

### Context 1: Deployer-Side Modernization

Modernize the deployer's local operations with ng-first patterns:

1. **ng-first invocation layer**: `nix build`, `nix copy`, preflight checks, and schema validation adopt `nixos-rebuild-ng` for better diagnostics and structured execution.

2. **Deterministic phased deploy execution:**
   - Config/schema validation (early, fail-closed)
   - Target/preflight validation (host reachability, auth, tooling)
   - Build strategy decision (`local` vs `remote`)
   - Build execution and artifact transfer
   - Activation (with pre/post hooks)
   - Post-activation verification

3. **Strict production mode:**
   - Explicit deployment mode, host/user/port specification
   - Explicit build strategy selection
   - Fail-closed on ambiguity

4. **Minimal optional dependencies:**
   - Cosmetic tooling (`lolcat`, `figlet`) optional or removed from core path
   - Core deploy path has no runtime surprises

### Context 2: Hermetic Payload (Tool Selection Model)

The hermetic payload is **not** a deployment of the deployer's nixpkgs. It is an **explicitly selected set of tools** chosen by the user based on the target's capabilities and the migration strategy.

**Design principles:**
1. **User-chosen tool versions**: The user specifies what `nixos-rebuild` (and `nix`) package ships to the target. This decouples the rebuild engine from the deployer's environment.
2. **Legacy-compatible by default**: If unspecified, the payload defaults to the deployer's `nixos-rebuild` (current behavior), preserving backward compatibility.
3. **Incremental migration support**: Users pin older nixpkgs revisions to ship matching `nixos-rebuild` versions for stateful/DB migrations.
4. **Leapfrog upgrade support**: Users ship the latest `nixos-rebuild-ng` (or any custom rebuild tool) to jump from NixOS 21.11 directly to unstable.
5. **Incubation-ready**: The same model extends to incubation — the payload can include `nixos-install` and a full system closure for bare-metal conversion.

### Hermetic Tool Selection Model (`hermetic` as set, not bool)

```nix
_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";

  hermetic = {
    enable = true;          # was the old `hermetic` boolean

    # Explicit rebuild engine to ship to target (optional)
    # Defaults to deployer's nixos-rebuild (current behavior)
    nixos-rebuild = <package>;

    # Explicit nix binary to ship to target (optional)
    # Defaults to deployer's nix
    nix = <package>;

    # Strategy: "copy-rebuild" (hermetic) or "copy-install" (incubation)
    # strategy = "copy-rebuild";
  };
};
```

### Evaluation-Time Preflight Checks (`nix flake check`)

Generating `checks` outputs alongside deploy apps, gated by a `check = true` (default) option in `_module.args.nixinate`:

```nix
checks.x86_64-linux.preflight-myMachine = runCommand "check-${machine}" { } ''
  # Validate required fields present
  # Validate SSH key paths exist
  # Validate port format
  # Validate buildOn value is "local" or "remote"
  # Validate hermetic config internal consistency
  # Validate selected nixos-rebuild package exists
  # Validate target host format
  touch $out
'';
```

These appear in `nix flake check` output, catch errors before any deployment begins, and can be individually run. Optional but **default-on**.

---

## Documented Deployment Patterns

The flexible tool selection model enables two critical deployment workflows that must be documented in README, MNGA plan, and all reference materials.

### Pattern 1: Incremental Migration

**Purpose:** Upgrade a machine across NixOS versions one step at a time, preserving database and state integrity at each step.

**How it works:** Pin the hermetic payload to an older nixpkgs revision matching the target's current version. Run `nixos-rebuild switch` using the *same* nixpkgs the target is running. Then repeat with the next version. State migrations happen one step at a time.

```nix
# NixOS 21.11 → 23.05 migration: first step
# Stay on 21.11 for the rebuild engine, upgrade the configuration gradually
oldPkgs = import nixpkgs {
  system = "x86_64-linux";
  rev = "21.11";  # pin to target's current nixpkgs
};

_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  hermetic = {
    enable = true;
    nixos-rebuild = oldPkgs.nixos-rebuild;  # ship matching rebuild engine
  };
};
```

**When to use:** Database servers, stateful applications, any deployment where a single big leap risks data loss or service interruption.

### Pattern 2: Leapfrog Upgrade

**Purpose:** Jump from an ancient NixOS version (e.g. 21.11) directly to the latest unstable, bypassing intermediate NixOS releases entirely.

**How it works:** Ship the latest `nixos-rebuild-ng` (or whichever rebuild tool from `nixos-unstable` / detsys the user chooses) as the hermetic payload. The remote never evaluates with its own Nix — it uses the shipped tool. This works because hermetic mode copies both Nix and the rebuild engine.

```nix
# NixOS 21.11 → unstable: one leap
latestPkgs = import nixpkgs {
  system = "x86_64-linux";
  rev = "nixos-unstable";
};

_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";
  hermetic = {
    enable = true;
    nixos-rebuild = latestPkgs.nixos-rebuild-ng;  # ship ng from unstable
    nix = latestPkgs.nix;                          # ship matching nix
  };
};
```

**When to use:** Machines with no critical state, clean deployments, test systems, or when the intermediate NixOS releases are not worth deploying.

### Pattern 3: Incubation Path (Future)

**Purpose:** Convert a non-NixOS Linux system (Ubuntu, Debian, Fedora) to NixOS using a hermetic-like payload.

**Extension of the tool selection model:** The payload includes `nixos-install` and a full system closure, rather than `nixos-rebuild`. The same `hermetic.nixos-rebuild` parameter can reference `nixos-install` for this workflow.

```nix
incubationPkgs = import nixpkgs { system = "x86_64-linux"; };

_module.args.nixinate = {
  host = "10.0.0.1";
  sshUser = "deploy";        # requires root SSH access
  hermetic = {
    enable = true;
    # strategy = "copy-install";     # incubation mode
    nixos-rebuild = incubationPkgs.nixos-install;
    # plus system closure, partition layout, etc.
  };
};
```

**When to use:** Bare metal, air-gapped sites, VM provisioning, any non-NixOS Linux target.

### Documentation Requirements

All three patterns must be documented with:
- Concrete configuration examples
- When-to-use guidance
- The tool version selection rationale
- Expected output and verification steps

The MNGA plan and README must carry this documentation; the refactoring plan references it.

---

## Shared Guidelines Alignment (`/speed-storage/opencode/llm/shared`)

This refactor plan is aligned to reviewed shared guidance:

- `/speed-storage/opencode/llm/shared/prime_directives.md`
- `/speed-storage/opencode/llm/shared/NIX_FLEET_ENGINEERING_PRINCIPLES.md`
- `/speed-storage/opencode/llm/shared/NIX_LANGUAGE_GUIDE.md`
- `/speed-storage/opencode/llm/shared/common-infra-strategies.md`

### Alignment by Principle

1. **Flake-first, deterministic operations**
   - Plan remains flake-native and avoids non-flake deployment paths.
   - M1/M2 require explicit schema + preflight validation to reduce hidden runtime assumptions.

2. **Safety-first deployment posture**
   - Test-first behavior is treated as an explicit oversight decision in M0.
   - Strict mode and fail-closed validation are core architecture elements.

3. **Operational transparency and diagnostics**
   - M2 adds phase-based, actionable diagnostics.
   - Failure states are expected to be deterministic and reviewable.

4. **Secrets and remote-host discipline (Secrix-aware)**
   - Consumer migration explicitly accounts for remote deployment and host-key expectations.
   - No plan element requires changing cryptographic assets; deployments should continue to consume secret material through established Secrix patterns.

5. **Simplicity over complexity (KISS)**
   - Core path minimizes optional/cosmetic dependencies.
   - Monolithic script behavior is replaced with phased, testable execution boundaries.

### Milestone-Level Guideline Mapping

- **M0:** Policy decisions (ng requirement, compatibility scope, test-default posture).
- **M1:** Determinism + safety baseline (schema, argument handling, ng-first command path).
- **M2:** Transparent operations (structured diagnostics and preflight behavior).
- **M3:** Reliability boundaries (cross-arch behavior explicitly fixed or disabled).
- **M4:** Controlled migration and documented operational contract for consumers.

---

## Zipper Stage-Gate Delivery Model

This project uses a **zipper stage-gate** model with two coupled tracks:

- **Track A (Engine):** internal `nixinate` refactor/modernization gates
- **Track B (Consumer):** `NixOS-Configuration` compatibility gates

Progress to the next milestone requires both tracks to pass (or explicit human waiver).

### Global Invariants (Non-Break Policy)

These are mandatory across all milestones:

1. Existing consumer usage must continue to work without required refactor:
   - `nix run .#<host>`
   - `nix run .#<host> -- switch`
   - current `_module.args.nixinate` naming/shape
2. Default safety posture must not regress.
3. Any intentional behavioral tightening must be explicitly approved at gate review.

---

## Complete Stage-Gate Plan

### Stage M0 — Scope Lock + Gate Contract
**Objective:** ratify constraints, acceptance criteria, and testing matrix.

**Track A deliverables (Engine):**
- Finalize critical issue register and ownership.
- Freeze internal acceptance tests for identified issues.

**Track B deliverables (Consumer):**
- Freeze baseline compatibility contract from `/speed-storage/repo/DarthPJB/NixOS-Configuration`.
- Record baseline invocation patterns and CI assumptions.

**Gate G0 (must pass):**
- Non-break policy ratified.
- M1/M2 measurable acceptance criteria approved.

---

### Stage M1 — Compatibility-Preserving Core Refactor
**Objective:** modernize core internals without breaking consumer contract.

**Track A deliverables (Engine):**
- **Deployer-side modernization:** Introduce ng-first execution layer for deployer-local operations (`nix build`, `nix copy`, preflight). The hermetic payload is a separate concern.
- Replace brittle command string composition with structured argument handling.
- Add strict schema validation for `_module.args.nixinate` (with compatibility-safe defaults).
- Add preflight checks (connectivity/auth/tooling) with actionable failures.
- **Hermetic tool selection model:** Convert `hermetic` from bool to set (`hermetic.enable`, `hermetic.nixos-rebuild`, `hermetic.nix`). Default behavior preserves current semantics.
- **`nix flake check` integration:** Generate `checks` outputs alongside deploy apps for evaluation-time validation of `nixinate` configuration.

**Track B deliverables (Consumer):**
- Execute compatibility suite against existing `NixOS-Configuration` usage.
- Verify unchanged invocation semantics and expected outcomes.

**Gate G1 (must pass):**
- No required downstream refactor.
- Existing invocations still valid.
- Critical clusters A/B/C closed.

---

### Stage M2 — Hardening Closure (All Identified Issues to Date)
**Objective:** close all currently identified internal issues and finalize production hardening.

**Track A deliverables (Engine):**
- Structured phase logging and diagnostics in deploy flow.
- Resolve runtime dependency/design debt in core path.
- Fix or explicitly disable broken cross-arch hermetic behavior (with clear policy).
- Close all known issues identified in this planning cycle.

**Track B deliverables (Consumer):**
- Re-run compatibility and operational checks on representative hosts/workflows.
- Validate CI/logging assumptions still function or are mapped with non-breaking defaults.

**Gate G2 (must pass):**
- All identified internal issues fixed or explicitly retired with approved rationale.
- No required consumer refactor.
- Production-ready diagnostics and failure behavior confirmed.

---

### Stage M3 — Validation Matrix + Controlled Rollout
**Objective:** prove reliability under realistic deployment conditions.

**Track A deliverables (Engine):**
- Execute local/remote strategy matrix and failure-path tests.
- Finalize supported/unsupported behavior matrix.

**Track B deliverables (Consumer):**
- Validate against representative `NixOS-Configuration` host classes.
- Confirm no contract regressions in batch and single-host flows.

**Gate G3 (must pass):**
- Validation matrix complete.
- Rollout decision approved by human oversight.

---

### Stage M4 — Release + Stewardship
**Objective:** publish and operationalize stabilized refactor.

**Track A deliverables (Engine):**
- Release notes and architecture notes.
- Ongoing maintenance checklist.

**Track B deliverables (Consumer):**
- Consumer-facing migration guidance (for optional improvements, not break-fixes).
- Post-release verification and incident playbook.

**Gate G4 (must pass):**
- Release artifacts published.
- Operational ownership and follow-up cadence assigned.

---

## Phase Workstreams (Cross-Cutting)

1. **Command/Invocation Safety Workstream**
   - ng-first abstraction + robust arg handling (deployer-side only).
2. **Schema/Validation Workstream**
   - config contract, preflight, fail-closed behavior.
   - `nix flake check` integration for evaluation-time validation.
3. **Hermetic Tool Selection Workstream**
   - Convert `hermetic` from bool to set with configurable tool selection.
   - Document incremental migration and leapfrog deployment patterns.
   - Default behavior preserves current semantics (backward compatible).
4. **Diagnostics/Observability Workstream**
   - phase-logs, error taxonomy, operator guidance.
5. **Compatibility Workstream**
   - frozen contract checks against `NixOS-Configuration`.
6. **Release Governance Workstream**
   - gate reviews, risk exceptions, change records.

---

## Delegation Model (Recommended)

- **@tuvok-deepseek:** adversarial risk and failure-mode review at each gate.
- **@tpol-xai:** systems architecture coherence and trade-off analysis.
- **@tpol-minimax:** milestone planning, exit criteria quality, and risk matrix maintenance.
- **@tpol-gpt:** consumer compatibility verification on `/speed-storage/repo/DarthPJB/NixOS-Configuration`.
- **@ezri-claude-haiku:** plan/document rewrites after each gate decision.

---

## Gate Checklists (Actionable)

### G0 Checklist
- [ ] Non-break invariants approved
- [ ] M1/M2 objective acceptance criteria approved
- [ ] Compatibility baseline frozen

### G1 Checklist
- [ ] Deployer-side ng-first layer integrated (separate from hermetic payload)
- [ ] Command-construction hardening complete
- [ ] Preflight + schema checks active
- [ ] Hermetic tool selection model implemented (`hermetic` as set, backward-compatible)
- [ ] `nix flake check` integration generating preflight validation checks
- [ ] Incremental migration and leapfrog patterns documented
- [ ] Existing consumer usage passes unchanged

### G2 Checklist
- [ ] all identified internal issues resolved/retired with approval
- [ ] diagnostics and dependency hardening complete
- [ ] cross-arch hermetic policy resolved (fix or disable)
- [ ] compatibility reconfirmed

### G3 Checklist
- [ ] validation matrix complete
- [ ] representative host/workflow coverage complete
- [ ] rollout risk accepted by oversight

### G4 Checklist
- [ ] release docs complete
- [ ] consumer guidance complete
- [ ] post-release ownership assigned

---

## Resolved Decisions

1. **ng is deployer-side only.** The hermetic payload (shipped to target) is a **user-selectable tool**, not a deployment of the deployer's nixpkgs. ng modernization applies to deployer-local operations (`nix build`, `nix copy`, preflight checks). The hermetic payload must remain compatible with classic `nixos-rebuild` on legacy NixOS 21.11+ targets.
2. **`hermetic` becomes a set, not a bool.** The tool selection model allows per-deployment choice of `nixos-rebuild` and `nix` packages shipped to the target. Default behavior preserves current semantics (ship deployer's `nixos-rebuild`).
3. **Incremental migration and leapfrog patterns are explicit features.** The tool selection model exists specifically to support these workflows. They must be documented as first-class deployment patterns.
4. **`nix flake check` integration is a goal.** Evaluation-time validation (optional, default-on) via generated `checks` outputs.

## Open Decisions for Human Oversight

1. Should `nix run .#<host>` remain default-test semantics permanently?
2. For cross-arch hermetic behavior: fix now or defer to a future phase? (Currently deferred — cross-arch exploration and testing needed before decision.)
3. What explicit waiver format should be used if a gate cannot be fully satisfied?
4. What cadence do you want for gate review sessions (e.g., per PR, weekly, milestone-end)?

---

## Change Log

- 2026-05-24: Added two-context architecture (deployer-side vs hermetic payload). Converted `hermetic` from bool to tool selection model. Documented incremental migration and leapfrog patterns. Added `nix flake check` integration concept. Clarified that ng modernization is deployer-side only, not a hermetic payload requirement.
- 2026-05-03: Synthesized from multi-agent architecture review. Prioritized critical modernization clusters and phased implementation strategy.
