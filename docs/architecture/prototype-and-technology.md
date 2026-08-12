# Blockmon Prototype & Technology

| | |
|---|---|
| **Status** | **v0.3** — gate categories frozen; numeric thresholds are measurement targets, not architecture truths; no technology selected |
| **Last reviewed** | 2026-08-11 |
| **Owns** | Acceptance gates (canonical definitions), experiments, cost-model method, candidate evaluation, eligibility procedure |
| **Depends on** | All other documents (requirements; not restated). Superseded by the architecture-choice ADR once recorded |

The prototype is the smallest experiment capable of **disproving** the architecture, not a miniature production system. Gates establish viability; selection is comparative.

---

## 1. Prototype Transitions

- **Transition 0 (throwaway infrastructure smoke)**: trivial state transition proving build targets, canonical encoding, hashing, candidate-machine integration, basic replay. Failures here are infrastructure, not semantics.
- **Transition 1 (the acceptance transition)**: permit reservation and consumption, assigned entropy, kernel capture roll, capability consumption, new creature in the authenticated tree, root update. Exercises discovery boundary, entropy ordering, determinism, state authentication, supply accounting and settlement in one path.
- Prototype batches are **region-scoped**; cross-region ordering is out of scope and this scoping is declared so DA/sequencing measurements are read against the right requirement.

## 2. Acceptance Gates

### G0 — Conformance (blocks everything)

- **0a smoke**: 10³-10⁴ vectors including hand-built edge cases, byte-identical canonical transcripts and roots across x86-64/ARM64/RISC-V.
- **0b hardening**: ≥10⁶ fuzzed transitions, same criterion; permanent CI gate.
- **0c independent implementation**: a second kernel implementation built from the written spec (no reference-source reuse) matches canonical vectors.
- **0d reproducible artefact**: third party rebuilds the canonical verification artefact bit-identically from source + pinned toolchain + recipe (register Q11). Includes the artefact-change drill: a toolchain bump must pass the conformance obligation (`protocol.md` §9) as a VerificationManifest-only change.
- **All corpora assert the conservation identities** (`protocol.md` §10) in addition to equality. Cross-platform agreement alone cannot pass G0.

### G1 — Resource Budgets

Native transition latency (p50/p95/p99) and batch replay throughput; in-machine slowdown vs native; full-day batch replay in a small fraction of a day on commodity hardware; kernel proving cost per transition and per aggregated epoch. Thresholds set after the representative transition exists.

### G2 — Canonical Identity

Same source and corpus produce identical canonical transcript, state and root native vs in-machine. Machine-level runtime traces may differ; canonical semantics may not.

### G3 — Independent Replay

A third party, from public data plus the written spec only (no operator API, database, interpretation, or binaries), reconstructs transitions to identical roots with an independently built tool.

### G4 — Data Availability

Historical reconstruction with the operator dead; intentional withholding must block finalisation rather than surface later as failed replay. Verified by a party with no operator relationship.

### G5 — Adversarial Challenge

Corrupted **simulation** output, corrupted **kernel** output, and invalid inclusion proof are each permissionlessly detected and rejected. Measured: challenger cost; honest-party amplification under concurrent Sybil disputes; **worst-case resolution time (feeds the recovery-timing inequality)**; capital lockup. Where a candidate documents sublinear defender growth, measure it, do not assume it.

### G6 — Escape and Continuity

- **Individual exit**: operator dead, and operator censoring; player credentials + public data only.
- **Aggregated exit**: a third party batches many exit claims into one settlement action.
- **Relaunch drill**: an independent implementer resumes the system from snapshot + DA + spec + artefacts through the full procedure (`verification.md` §8), including succession claim, **with an unresolved claim and an unresolved entropy round outstanding at the moment of failure**, and processing a batched exit, with a **provider-removal matrix** (DA gateway, indexer, RPC, official builds, operator explorer each removed).
- Mass-exit workload modelled at 1%/10%/100%; execution not required, arithmetic is.

### G7 — Cost Model

Workload-derived, no fixed budget hypotheses: representative actions/subject/day, canonical bytes/action, kernel-DA vs simulation-transcript-DA (horizon-scoped) streams, settlement and proving costs, per-MAU decomposition, per-action sponsor cost (sponsored-fee exhaustion exposure). Gating shape: settlement sublinear via aggregation; DA linear in compressed information; player-visible ~0; amortised cost within a separately ratified budget.

### G8 — Liveness and Clock Composition

The clocks of `verification.md` §10 measured, including adversarial challenge resolution and the censorship bound; then the **composed inequalities of `architecture.md` §15 verified with measured values**, including `challenge + checkpoint publication + margin < guaranteed DA retention` for the candidate's actual DA layer.

### G9 — Temporal Safety

Mechanical rejection of a command sequenced after its entropy reveal; withholding by player, sequencer (including **reveal withholding**) and provider each resolves per `protocol.md` §5 with no reroll; end-to-end commit-to-resolution latency measured on a real mobile network against the pause-tolerant budget.

### G10 — Reconciliation Drill

The corrupted-early-output scenario (`verification.md` §6) against a real materialised store, index and client cache: correction must propagate by re-execution and re-projection without manual repair, with measured workload.

Privacy-leakage assessment is deferred from the falsifying prototype to the production ADR (the minimisation design does not need a prototype to be falsified).

## 3. Experiments

Common to all: same kernel, same corpus, Transition 0 before Transition 1; early failure kills later work.

- **A — Cartesi path**: A1 machine feasibility (reference source → riscv64 → machine; G0a/G2), A2 dispute (G5, including multi-Sybil defender growth), A3 DA + aggregation (G4/G7; the decisive investigation), A4 recovery (G6/G8).
- **B — Avalanche path**: B1 minimal constitutional contract on a local L1 (G4/G6/G7/G8; explicit DA strategy required, since consensus data possession is not recovery DA); B2 verification-sovereignty feasibility spike (scoped estimate, not a build).
- **C — Cardano path**: C1 quorum root acceptance; C2 kernel validity-verifier feasibility over Plutus V3 BLS primitives; C3 neutral forced-exit representation (G6). The kernel/simulation split makes C2 the interesting question; full-simulation verification is not asked of any candidate.
- **D — Arbitrum/Nitro path**: D1 stock app-chain commitments + DA + escape economics; D2 custom-STF spike: whether the kernel survives translation into the Nitro STF/replay model with acceptable single-source properties.
- **E — Generic zkVM kernel rollup (admitted by the kernel split)**: kernel validity proofs via a general zkVM with the simulation layer optimistic/replay-audited; feasibility spike before it earns full candidate status.

## 4. Eligibility and Selection

```
gate failure → candidate rejected or redesigned
all required gates passed → ADR-eligible
2+ eligible → comparative ADR: security assumptions, maturity, operational burden,
              external dependencies, cost curves, verification sovereignty,
              escape/continuity guarantees, engineering ownership, migration risk
```

There is no ranking and no first-past-the-post. A failure-routing table may order **effort** (e.g. if Cartesi fails only DA economics, try alternate DA for the same machine before evaluating D2), and orders nothing else. The candidates' settlement layers are additionally evaluated against the succession and snapshot-pointer requirements (`verification.md` §8), which entered after the original candidate write-ups.

## 5. Candidate Notes (role view, no ranking)

| Property | Cartesi rollup | Avalanche L1 | Cardano settlement | Arbitrum/Nitro | zkVM kernel rollup |
|---|---|---|---|---|---|
| Canonical machine alignment | strong (single-source RISC-V) | must build | external/bespoke | moderate (custom STF) | kernel-scoped |
| Dispute machinery | Dave (young; measure) | none: build | none native | BoLD/Nitro (mature) | n/a (validity) |
| Validity path | zkVM over machine (open) | self-built | plausible for kernel via BLS primitives | possible, not native focus | native |
| Settlement neutrality | strong | own validators | strong | strong | depends on parent |
| DA for recovery | modular: investigate | must design explicitly | external | configurable | configurable |
| Status | prototype required | blocked pending verifier + DA design scope | prototype required (kernel-validity feasibility) | prototype required (STF translation) | spike required |

## 6. Deliverables

1. Conformance suite (0a vectors + edge cases; 0b fuzz harness; conservation assertions; permanent CI asset).
2. Kernel prototype: permit reservation/consumption, assigned entropy, capture roll, capability accounting, authenticated tree; Transition 0 harness.
3. Written protocol spec sufficient for 0c, plus the independent replay tool (different engineer, no reference-source reuse).
4. Independent kernel implementation (0c).
5. Per-experiment measurement reports, gate by gate, raw numbers.
6. Cost model per §2 G7.
7. Comparative ADR draft, recorded only from measured results.
