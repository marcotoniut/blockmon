# Blockmon Verification, Recovery & Liveness

| | |
|---|---|
| **Status** | **v0.2** — requirements stable; verification mechanisms experimental by design |
| **Last reviewed** | 2026-08-11 |
| **Owns** | Conformance model, canonical verification machine, verification maturity/modes, claim/challenge state machine, corrections and derived state, DA mechanics, recovery/relaunch/succession, exits, liveness, verifier resource budgets |
| **Depends on** | `architecture.md`, `protocol.md` (invariants and semantics; not restated) |

How Blockmon moves from trusted execution towards permissionless correctness, and how the system survives its operators, without selecting infrastructure.

---

## 1. What Gets Verified, and How Strongly

Verification targets split along the kernel/simulation boundary (`architecture.md` §4):

- **Constitutional kernel**: small enough for independent reimplementation and, eventually, validity proofs. Its guarantees are the constitutional ones.
- **Deterministic simulation layer**: replayable and fraud-provable indefinitely; validity-proving full simulation is not assumed on any timeline. Envelopes bound whatever verification has not yet covered.

The transition function never changes across verification stages or modes; only the acceptance rule for claimed roots changes.

## 2. Conformance

Two distinct obligations (both gated, `prototype-and-technology.md` G0):

- **Cross-target determinism**: the same implementation produces byte-identical canonical transcripts and roots on x86-64, ARM64 and RISC-V, native and in-machine.
- **Independent semantic conformance**: a second kernel implementation, built from the written specification without reading or linking the reference core, matches canonical vectors byte-exactly. The written spec and vectors, not any implementation, are the semantic anchor.
- Conformance vectors assert the **conservation identities** (`protocol.md` §10) over fuzzed states, not just equality: implementations can agree on an economically unsound transition.

## 3. Canonical Verification Machine

Disputes and proofs operate over a machine, not source code; "what machine is being proven?" must have one canonical answer, recorded in the VerificationManifest. Current candidate: RISC-V execution of the same consensus-core source (the reference implementation has a linux/riscv64 target). A compilation target is not determinism: native and in-machine builds must be transcript- and root-identical, which the conformance suite exists to prove. Machine artefacts are reproducibly buildable (`protocol.md` §9).

## 4. Verification Maturity and Modes

```
Authority  →  Quorum  →  Permissionless { optimistic | validity | hybrid }
```

- **Stage A, Authority**: operator verifies and signs roots. Guarantees: tamper-evidence, issuance/signature/reservation enforcement. Explicit absence: execution honesty. Launch-minimum set applies (`architecture.md` §18).
- **Stage B, Quorum**: N independent validators replay from DA using the conformance-verified core; acceptance under an explicit fault assumption with transparent membership. Collusion beyond the assumption can finalise a false root: quorum reduces trust, it does not remove it.
- **Optimistic mode**: an invalid claim is permissionlessly challengeable and reducible to bounded adjudication. The dispute system SHALL have bounded resolution time, resist griefing and challenger-Sybil amplification (defence cost sublinear in attacker count), require at most one honest verifier for safety, and bond claims and challenges. Interactive bisection to single-step adjudication is one valid family, not the requirement.
- **Validity mode**: state-transition proofs over the canonical machine for the **kernel**, recursively aggregated to one bounded proof per epoch. The kernel SHALL remain provable and SHALL NOT be prematurely distorted around one proving system.
- **Verification versioning**: a settled claim binds (ProtocolManifest, VerificationManifest); historical commitments remain verifiable under the semantics active at acceptance.

## 5. Claim / Challenge State Machine

- Claims are **immutable once published**; supersession happens only through the correction procedure, never by silent replacement.
- Claims and challenges are **keyed to roots, not committer identities**; succession does not invalidate or orphan active disputes.
- A successful challenge triggers correction: deterministic re-execution of the permanent input sequence from the last correct root (`protocol.md` §7). Claims by a failed committer that never reached output finality are discarded and recomputed, not adjudicated.
- Challenge windows and worst-case adversarial resolution are measured quantities feeding the clock inequalities (`architecture.md` §15).

## 6. Corrections and Derived State

Canonical correction is mechanical (suffix re-execution, bounded by the challenge horizon and the replay budget). The operational requirement is on everything downstream:

- **Every derived system is a root-addressed projection with retraction support**: it records the claimed root it derived from and consumes correction events (deterministic transcript diffs) like any event.
- Reconciliation is asynchronous with monotone convergence; gameplay continues against the corrected sequenced tip.
- Sub-final data crossing into systems that cannot retract (sent notifications, third-party scrapers) is the residual laundering surface; the finality consumption matrix (`protocol.md` §7) and counterparty replay bound it.
- The **reconciliation drill** (corrupt an early claimed output, correct it, verify every projection converges without manual repair) is a required gate.

## 7. Data Availability Mechanics

- Canonical inputs remain retrievable for the full challenge horizon; batches without available data cannot finalise; withholding is protocol-visible.
- DA is a bounded window, not recovery storage (`architecture.md` §10); the recovery-timing inequality (`protocol.md` §12) binds horizon, checkpoint cadence and the DA retention actually guaranteed by the chosen layer.
- Challenges and exits are meaningful only while DA holds; that coupling is why availability failure must halt finalisation rather than surface later as failed replay.

## 8. Recovery, Relaunch and Succession

**Recovery point**: the latest checkpoint recorded on settlement. Freshness from the settlement pointer, content from any mirror, integrity from the root; a malicious mirror can serve nothing useful.

**Relaunch procedure requirements** (the drill in `prototype-and-technology.md` G6):

1. reconstruct state from snapshot + DA-window inputs, verifying against settled roots;
2. re-derive outputs for input-final transitions past the checkpoint; discard the dead operator's unverified claims;
3. resolve pending entropy via the assignment rule against the still-independent source;
4. continue sequencing and settlement after succession;
5. process individual and batched exits.

No step may require an operator-hosted service: multiple DA retrieval paths, rebuildable indexes, reproducible artefacts, key-based subject identity. Degraded mode is explicit: without a Discovery Authority, issuance pauses; everything else continues.

**Succession requirements** (frozen; algorithm deliberately open, register Q4):

- eligibility triggered only by **settlement-visible liveness failure** (missed on-chain commitments), never off-chain observation;
- claiming is permissionless (bonding acceptable) and arbitrated by the settlement layer, which is the single continuity selector: competing runtimes can compute, only one can settle;
- prior committer authority deactivates when succession finalises; a returning operator has no special path back;
- active disputes survive succession (§5).

## 9. Exits

Individual: prove entitlement against settled state, operator-independent, relayable by any fee-payer. Aggregated: any party batches many exit claims into one settlement action; this is a requirement, not an optimisation, since per-player settlement transactions cannot clear a mass exit at realistic chain capacity. Exit intents lock assets positionally (`protocol.md` §13). No key can pause exits.

## 10. Liveness

Measured, not assumed (gates G8/G9):

| Clock | Requirement |
|---|---|
| Soft confirmation | product-defined; sequenced receipt latency |
| Input finality | batch posting cadence; a product parameter with cost trade-offs (register Q10) |
| Output finality | per active stage/mode; adversarial bound measured |
| Entropy resolution | commit-to-resolution seconds-class on real mobile networks |
| Forced exit | bounded worst case under maximal griefing; feeds upgrade protection |
| Censorship | ignored submission to guaranteed inclusion, provable from receipts + DA |

All feed the composition inequalities in `architecture.md` §15; the composed values, not the individual bounds, are the safety property.

## 11. Verifier Resource Budgets

Gated, not informative: a validator must replay a full day's batches in a small fraction of a day on commodity hardware; an honest challenger's cost under concurrent adversarial disputes must grow sublinearly with attacker count; kernel proving cost must be compatible with per-epoch aggregation. The kernel step budget (`protocol.md` §2) is what makes these bounds enforceable against pathological-but-valid transitions.
