# Nixinate Modernization Refactoring Plan (Synthesis Draft)

**Status:** Working Draft (Synthesized from multi-agent review)  
**Date:** 2026-05-03  
**Project Path:** `/speed-storage/repo/DarthPJB/nixinate`  
**Consumer Reference Path:** `/speed-storage/repo/DarthPJB/NixOS-Configuration`  
**Primary Goal:** Modernize nixinate for production safety and `determinate-systems/nixos-rebuild-ng` support, prioritizing critical risks first.

---

## 1) Scope and Intent

This plan is focused on:
- eliminating high-risk deployment behavior,
- aligning the deploy engine with modern ng-based rebuild workflows on the **deployer side**,
- simplifying architecture for deterministic, testable operation,
- and supporting a controlled migration path for existing consumers.

**Critical architectural distinction:** The deployer-side operations (`nix build`, `nix copy`, preflight checks) can modernize freely with ng. The **hermetic payload** (the tools shipped to the target) is a **user-selectable tool set** — it must remain compatible with legacy NixOS 21.11+ targets. These are separate concerns. Treating the hermetic payload as a modernization target would break nixinate's core value proposition.

Legacy support in the hermetic path is not "legacy behavior" — it is **the feature**. The refactoring preserves and strengthens it through explicit tool selection.

---

## 2) Correlated Critical Issue Clusters

## Cluster A — Rebuild Engine Modernization Blocker (**CRITICAL**)

**Problem:** Current deploy path is hard-coupled to classic `nixos-rebuild` calls and does not implement `nixos-rebuild-ng` detection/integration on the deployer side.

**Evidence:**
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` line 24 (`nixos-rebuild` override)
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` lines 69, 72, 77 (direct command invocation paths)

**Why this matters:** Production deployments are anchored to legacy semantics on the **deployer side**. The deployer's local build/copy commands should adopt ng for better diagnostics. However, this is separate from the **hermetic payload** (shipped to target), which must support legacy NixOS 21.11+.

**Context separation:**
- **Deployer-side** (ng target): `nix build`, `nix copy`, preflight checks, schema validation
- **Hermetic payload** (user-selectable): rebuild engine shipped to target, must work on legacy systems
- These are separate workstreams with separate acceptance criteria

---

## Cluster B — Unsafe / Brittle Command Construction (**CRITICAL**)

**Problem:** Deployment command assembly relies on shell string concatenation and interpolated user-configured args (e.g., `nixOptions`, mode argument), creating high fragility and potential injection/quoting failures.

**Evidence:**
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` line 50 (`concatStringsSep " "`)
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` lines 69, 77 (embedded command strings)

**Why this matters:** Unclear quoting and shell composition can fail unpredictably under production edge cases and complicates ng migration.

---

## Cluster C — Missing Preflight Validation and Weak Contract Enforcement (**CRITICAL**)

**Problem:** `_module.args.nixinate` contract is only partially guarded; failures can occur late during runtime (host/auth/port/tooling assumptions not verified pre-deploy).

**Evidence:**
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` line 39 validates `sshUser` but not equivalent strict validation for all required fields.
- No explicit preflight phase in generated deploy flow.

**Why this matters:** Production deployments fail late after expensive steps and produce weaker operational diagnostics.

---

## Cluster D — Cross-Architecture Hermetic Path Known-Broken (**HIGH**)

**Problem:** Hermetic activation path includes an acknowledged cross-architecture failure.

**Evidence:**
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` line 69 TODO comment indicates cross-arch failure.

**Why this matters:** Multi-architecture fleets cannot safely rely on this path; behavior is known inconsistent.

---

## Cluster E — Runtime Dependency/Operational Design Debt (**HIGH**)

**Problem:** Generated deploy scripts depend on presentation/concurrency tools (`lolcat`, `figlet`, `parallel/sem`) and use monolithic logic, which raises runtime and maintenance risk.

**Evidence:**
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` lines 35–36 (`lolcat`, `sem`)
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` line 58 (`figlet`)
- `/speed-storage/repo/DarthPJB/nixinate/flake.nix` line 85 (`runtimeInputs = [ ]`, reinforcing fragility concerns from reviewers)

**Why this matters:** Increases failure surface, hinders portability, and complicates structured testing.

---

## 3) Consumer-Side Compatibility Risks (NixOS-Configuration)

From usage review at `/speed-storage/repo/DarthPJB/NixOS-Configuration`:

1. **Default mode assumptions are sensitive** (**CRITICAL**)
   - Existing workflows assume default behavior is safe/test-first.
2. **CLI pass-through contract must remain deliberate** (**CRITICAL**)
   - Common usage pattern: `nix run .#host -- switch`.
3. **`buildOn = "remote"` hosts require explicit ng-capable path** (**CRITICAL/HIGH**)
   - Example host class includes remote-build machines.
4. **CI build/deploy commands still include legacy patterns** (**HIGH**)
   - Build/deploy workflows need explicit migration steps.
5. **Operational log path/shape may be assumed by CI** (**MEDIUM/HIGH**)
   - Changes must include artifact-path review.

---

## 4) Target Architecture (Proposed)

Adopt a **two-context architecture** distinguishing deployer-side operations from the hermetic payload shipped to targets.

### Context 1: Deployer-Side Modernization

1. **ng-first invocation layer (deployer-side only)**
   - `nix build`, `nix copy`, preflight checks, schema validation adopt ng for better diagnostics. The hermetic payload is a separate concern.
2. **Phased deploy engine**
   - Split into deterministic stages:
     1) config/schema validation (including `nix flake check` integration)
     2) target/preflight validation
     3) build strategy decision (`local` vs `remote`)
     4) transfer/build execution
     5) activation
     6) post-activation verification
3. **Strict production mode**
   - Fail-closed with explicit mode, explicit host/user/port, and explicit strategy.
4. **minimal dependency output**
   - Make cosmetic dependencies optional or remove from core deploy path.

### Context 2: Hermetic Payload (Tool Selection Model)

The hermetic payload is **not** a deployment of the deployer's nixpkgs. It is an **explicitly selected set of tools** chosen by the user based on the target's capabilities and migration strategy.

Key design:
- **`hermetic` becomes a set** (`enable`, `nixos-rebuild`, `nix`), not a bool
- User specifies what rebuild engine ships to the target
- Default behavior preserves current semantics (backward compatible)
- Enables two documented patterns:
  - **Incremental migration**: pin older nixpkgs revisions for stepwise stateful upgrades
  - **Leapfrog upgrade**: ship latest ng (or any rebuild tool) directly to NixOS 21.11+
- Extends to incubation: payload can include `nixos-install` for bare-metal conversion

### Evaluation-Time Validation (`nix flake check`)

Generate `checks` outputs alongside deploy apps, gated by `check = true` (default):
- Required field presence and type correctness
- SSH key paths exist
- Port format, buildOn value, hermetic config consistency
- Selected nixos-rebuild package validity
- Catches errors before any deployment begins

---

## 5) Milestones and Exit Criteria

## M0 — Plan Ratification
- Confirm hard requirements:
  - ng on deployer side only (not a hermetic payload requirement)
  - required compatibility surface for existing users
  - tool selection model ratified
- **Exit:** acceptance criteria signed off.

## M1 — Critical Foundation (Modernization + Safety + Tool Selection)
- Integrate ng-first execution path on **deployer side** (separate from hermetic payload).
- Replace brittle string assembly with safer command argument handling.
- Enforce schema validation early.
- **Convert `hermetic` from bool to set** with configurable `nixos-rebuild` and `nix` packages.
- Add `nix flake check` integration for evaluation-time validation.
- **Exit:** critical clusters A/B/C addressed; tool selection model implemented; backward compatibility preserved.

## M2 — Diagnostics + Operational Hardening
- Add preflight checks (host reachability, auth expectations, tooling availability).
- Add structured/loggable phase output and clearer failure messages.
- Document incremental migration and leapfrog deployment patterns in README and MNGA plan.
- **Exit:** predictable failure behavior with actionable diagnostics; patterns documented.

## M3 — Cross-Arch and Strategy Hardening
- Cross-arch: requires exploration and testing before decision. Deferred to future phase.
- Validate local/remote strategy behavior against representative targets.
- **Exit:** documented, reliable behavior matrix.

## M4 — Consumer Migration + Release
- Publish migration guide for existing usage patterns.
- Update CI examples and recommended invocation contract.
- **Exit:** upgrade path validated in `/speed-storage/repo/DarthPJB/NixOS-Configuration`-style consumers.

---

## 6) Immediate Implementation Priorities (Ordered)

1. **Define and freeze minimal `_module.args.nixinate` schema** (required/optional fields, strict defaults), including the `hermetic` set with `enable`, `nixos-rebuild`, and `nix` fields.
2. **Implement ng-first command layer behind a clean interface** (deployer-side only — separate from hermetic payload).
3. **Convert `hermetic` from bool to set** with backward-compatible defaults.
4. **Add `nix flake check` integration** for evaluation-time validation.
5. **Refactor deploy script generation into phase functions**.
6. **Add preflight + postflight checks**.
7. **Reduce optional tooling in core path** (`lolcat`/`figlet`/`sem` behavior review).
8. **Document incremental migration and leapfrog patterns** in README and MNGA plan.

---

## 7) Resolved Decisions

1. **ng is deployer-side only.** The hermetic payload is a user-selectable tool set, not a deployment of the deployer's nixpkgs. ng modernization applies to deployer-local operations. The hermetic payload must remain compatible with classic `nixos-rebuild` on legacy NixOS 21.11+ targets.
2. **`hermetic` becomes a set** with `enable`, `nixos-rebuild`, and `nix` fields. Default behavior preserves current semantics.
3. **Incremental migration and leapfrog patterns are explicit, documented features.** The tool selection model exists specifically to support these workflows.

## 8) Open Decisions for Human Oversight

1. Should `nix run .#<host>` remain default-test semantics permanently?
2. Cross-arch hermetic: needs exploration and testing before decision (deferred to future phase).
3. What is the minimum consumer migration guarantee (1 release cycle vs immediate cutover)?

---

## 9) Change Log

- 2026-05-24: Added two-context architecture (deployer-side vs hermetic payload). Converted `hermetic` from bool to tool selection model. Added incremental migration and leapfrog deployment patterns. Added `nix flake check` integration concept.
- 2026-05-03: Initial placeholder created.
- 2026-05-03: Replaced with synthesized multi-agent modernization plan and prioritized issue clusters.

---

## 8) Change Log

- 2026-05-03: Initial placeholder created.
- 2026-05-03: Replaced with synthesized multi-agent modernization plan and prioritized issue clusters.
