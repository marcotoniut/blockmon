# Blockmon Prototype & Technology

| | |
|---|---|
| **Status** | **v0.4**, gate categories frozen; numeric thresholds are measurement targets, not architecture truths; no technology selected; re-sequenced 2026-09-01: the battle-channel E2E slice (§2) precedes Transition 1 |
| **Last reviewed** | 2026-09-01 |
| **Owns** | Current implementation priority (§2), acceptance gates (canonical definitions), experiments, cost-model method, candidate evaluation, eligibility procedure |
| **Depends on** | All other documents (requirements; not restated). Superseded by the architecture-choice ADR once recorded |

The prototype is the smallest experiment capable of **disproving** the architecture, not a miniature production system. Gates establish viability; selection is comparative.

---

## 1. Prototype Transitions

- **Transition 0 (throwaway infrastructure smoke)**: trivial state transition proving build targets, canonical encoding, hashing, candidate-machine integration, basic replay. Failures here are infrastructure, not semantics.
- **Slice B (battle-channel E2E, the immediate target)**: the smallest end-to-end proof of the integration boundaries: minimal representative deterministic transition, canonical encoding/hash/commitment, battle anchoring, session-secret derivation, one channel exchange, dual-signed checkpoint, cooperative settlement on a local chain, negative paths. Defined in §2. Slice B proves seams, not the constitution: DA, escape, issuance and succession remain gated by G4, G6, G7 and the experiments.
- **Transition 1 (the acceptance transition)**: permit reservation and consumption, assigned entropy, kernel capture roll, capability consumption, new creature in the authenticated tree, root update. Exercises discovery boundary, entropy ordering, determinism, state authentication, supply accounting and settlement in one path. Status: kernel implemented in `protocol/kernel` against `canonical-encoding.md` §6 (flat root stand-in; tree still OPEN), invariant suite green, kernel-backed vectors in the G0a corpus. Sequencing, DA and settlement integration remain the experiments' scope.
- Prototype batches are **region-scoped**; cross-region ordering is out of scope and this scoping is declared so DA/sequencing measurements are read against the right requirement.

## 2. Current Priority: the Battle-Channel E2E Slice

**The current goal is not to build a real Odin game client.** The immediate target is a barebones, end-to-end provable architecture running against a local test chain, with the Odin side kept to the absolute minimum necessary to prove the integration boundaries.

### 2.1 Scope

The slice contains, and deliberately little else:

- a deterministic kernel stub or minimal representative transition;
- canonical encoding/hash/commitment behaviour (its fixtures seed the G0a vectors);
- a local test chain trivial to start, reset and inspect (§2.3);
- a minimal settlement contract implementing the thin verifier (`battle-channel.md` §5), standing in for the canonical layer (`battle-channel.md` §1);
- battle creation/opening; anchoring participants and wallet-authorised ephemeral battle public keys;
- off-chain derivation of the battle session secret by both participants;
- one representative signed, hash-chained channel exchange;
- one dual-signed checkpoint or final result;
- cooperative on-chain settlement;
- the negative paths of §2.4;
- deterministic E2E tests proving the complete round trip.

### 2.2 The Odin probe

A **protocol probe, not a game client**: a tiny CLI/test harness capable only of constructing or loading deterministic test state; generating the ephemeral battle material the protocol requires; deriving the battle session secret; producing the representative signed/committed operation; talking to the local chain through the smallest practical RPC/ABI layer; submitting or observing settlement; asserting final state.

Battle-channel primitives (X25519, Ed25519, HKDF, SHA-2/BLAKE2b, AEAD) exist in Odin's `core:crypto`. Wallet and chain cryptography is **not** implemented in Odin: the probe delegates signing to an external signer/test-key helper (e.g. Foundry's `cast` over Anvil's deterministic accounts) behind a minimal adapter. `core:crypto` lacking secp256k1 and Ethereum Keccak-256 is therefore a settlement-adapter fact, not a kernel blocker (`architecture.md` §21).

Excluded, deliberately: UI; networking beyond what the E2E requires; matchmaking; real game loops; production wallet UX; account management; broad ABI/RPC abstractions; reusable client frameworks; speculative battle features; hand-rolled chain cryptography.

Generalisation constraint: the Solidity contract, Odin chain interface, ABI handling and Foundry harness are built only to what the slice exercises. Hard-coded, test-specific plumbing is preferred wherever the alternative is the accidental beginning of a production blockchain SDK or game client. The only artefacts written for reuse are the protocol fixtures and vectors, which feed G0 and the real kernel.

### 2.3 Local chain tooling

Chosen for the slice: **Foundry (Anvil + Forge + Cast)**, not yet installed locally. Against the requirements: one-command startup (`anvil`); deterministic funded accounts (fixed mnemonic); instant reset (restart, or `anvil_reset`); fast deployment (`forge script`/`forge create`); block/time manipulation for timeout tests (`evm_increaseTime`, `anvil_mine`, `anvil_setNextBlockTimestamp`); static binaries with straightforward CI execution. Hardhat Network offers equivalent manipulation on a Node toolchain this repo otherwise has no use for; dev-mode geth lacks the ergonomics. This is slice scaffolding optimised for deterministic E2E, **not** technology selection; the comparative ADR (§5) is untouched by it.

The on-chain verifier is written in the chain-native environment, for EVM most likely Solidity with small Yul/assembly sections only where justified (`battle-channel.md` §5). The battle simulator is never ported to Solidity for the prototype.

### 2.4 E2E shape and negative paths

```
start anvil
→ deploy minimal settlement contract
→ create battle
→ register/anchor participant battle public keys (wallet-authorised)
→ A and B derive the battle session secret off-chain
→ a few deterministic representative channel operations locally
→ build/sign/hash-chain final checkpoint
→ submit compact settlement
→ contract validates and records outcome
→ E2E asserts chain state and deterministic local state agree
```

Negative paths, cheapest first: **invalid signature rejected** and **duplicate settlement rejected** (pure Forge tests, near-free; both required); **stale checkpoint superseded**; **timeout settlement after advancing chain time** (needs the harness plus time manipulation; required unless it materially expands scope, as it is the only path exercising deadlines end to end).

### 2.5 What the slice proves, and what it does not

Proves: the cryptographic layer separation (`architecture.md` §21) is real at the code seams; canonical encoding/commitment determinism at small scale; the channel key hierarchy and session-secret establishment; the thin-verifier settlement boundary; O(1) cooperative settlement.

Does not prove: DA, escape/continuity, issuance envelope, succession, dispute-at-depth, cost model, or any candidate ranking. Those remain owned by the gates and experiments, unchanged. Nor does it prove the eventual hidden-information protocol: the single shared session secret is a demonstration of establishment, and mental-poker-class constructions remain open (`battle-channel.md` §3 scope note; Q15/Q17/Q18).

### 2.6 Dual-process extension

The slice also runs as **two independent participant processes** over a loopback
socket (`prototype/slice-b/battle.sh`; `just slice-b-battle-e2e` automated,
`just slice-b-battle` manual). Same battle, same contract, same canonical code:
each participant is its own program holding only its own ephemeral secrets, and
learns everything else from anchored public state and the frames it receives.

Each participant reads the anchored battle and the settled outcome from the chain
itself, through a read-only `eth_call` path with pinned selectors for one contract
(`architecture.md` §21: signing is delegated, reading is not). Wallet signing
remains outside Odin, and §2.2's "smallest practical RPC/ABI layer" bounds the
read path.

Adds to §2.5's proves list: the public/secret boundary survives a process
boundary rather than a function boundary; session establishment works between
separate participants, authenticated by wallet-anchored ephemeral keys plus proof
of possession; and the two-process transcript, checkpoint and channel signatures
are byte-identical to the single-process probe's promoted vectors. The
does-not-prove list stands unchanged, and this is **not** evidence for G0c: both
processes share `protocol/canonical`, so it is one implementation running twice.

### 2.7 Revised sequence

```
Slice B (E2E on local chain)                           complete, frozen
→ G0a smoke vectors (grown from slice fixtures)        complete
→ Transition 1 (capture path) + G0b fuzz               complete
→ G0c independent implementation; G0d reproducibility  G0c complete; G0d open (register Q11)  ← now
→ experiments A-E and G1-G10 as previously sequenced
```

Slice checks prefigure G2 (native determinism at small scale), G5 (negative paths as an embryo of adversarial rejection) and G9 (the timeout analogue). Prefiguring is not passage; every gate still runs in full.

## 3. Acceptance Gates

### G0 — Conformance (blocks everything)

Scope note: G0 covers **protocol cryptography only** (`architecture.md` §21): canonical encoding, protocol hashing and domain separation, commitment/tree semantics, cross-target determinism, reproducible artefacts. Settlement-interface cryptography (chain signatures, chain hashes) is exercised by the slice and the chain adapters, never by G0; a chain's primitives being absent from the kernel language blocks neither G0 nor kernel work.

- **0a smoke**: 10³-10⁴ vectors including hand-built edge cases, byte-identical canonical transcripts and roots across x86-64/ARM64/RISC-V. Status: closed. `conformance/` contains the immutable 51-check constitutional seed corpus, the seeded 1136-check expansion tier, the Odin generator, and an independent Python checker derived from `canonical-encoding.md` with no shared code. The seed corpus serves as historical evidence; only the expansion tier grows. `conformance/cross-target.sh` records byte identity for both corpora across four targets: darwin arm64, linux arm64, linux amd64, and linux riscv64. Because it requires docker and a riscv64 container, it remains off the per-change CI path. The intended shape is a scheduled or manually dispatched job, keeping the fast constitutional gates on every push and pull request.
- **0b hardening**: ≥10⁶ fuzzed transitions, same criterion; permanent CI gate. Status: closed. Property/fuzz harness at `conformance/fuzz` (`just g0b`; raw-struct generators, independent model oracle, canonical-bytes equality, seed-reproducible); >8M transitions across four seeds, including the pinned default 0xB10C0DE5EED (12166583181037, shared by `just g0b` and the bare binary), pass with zero counterexamples. Every push to main and every pull request triggers the permanent CI gate in `.github/workflows/conformance.yml`. This runs the lint gate, the kernel suite, g0a with a byte-identical corpus check, g0b at full budget, and g0c on its own toolchain path.
- **0c independent implementation**: a second kernel implementation built from the written spec (no reference-source reuse) matches canonical vectors. Status: closed. The cleanroom Rust kernel in `conformance/g0c/` reproduces both corpora at 1187/1187 from the written spec alone, deriving no value from a vector. This exercise yielded three corrections to `canonical-encoding.md`: assigned reject discriminants, the definition of valid kernel input, and the extant == created clause. `REPORT.md` records each isolated session verbatim.
- **0d reproducible artefact**: third party rebuilds the canonical verification artefact bit-identically from source + pinned toolchain + recipe (register Q11). Includes the artefact-change drill: a toolchain bump must pass the conformance obligation (`protocol.md` §9) as a VerificationManifest-only change. Status: open, with a scoped negative recorded. Protocol outputs are deterministic and project packages compile bit-identically, but whole Odin binaries are not: gensym counters in four runtime and os package symbols differ between builds, natively and inside a riscv64 container, with `-thread-count:1`. Nearest upstream issues are odin-lang/Odin #3028 and #6076. No binary normaliser is in use, since normalising would define away the nondeterminism this gate exists to detect.
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

## 4. Experiments

Common to all: same kernel, same corpus, Transition 0 before Transition 1; early failure kills later work.

- **A — Cartesi path**: A1 machine feasibility (reference source → riscv64 → machine; G0a/G2), A2 dispute (G5, including multi-Sybil defender growth), A3 DA + aggregation (G4/G7; the decisive investigation), A4 recovery (G6/G8).
- **B — Avalanche path**: B1 minimal constitutional contract on a local L1 (G4/G6/G7/G8; explicit DA strategy required, since consensus data possession is not recovery DA); B2 verification-sovereignty feasibility spike (scoped estimate, not a build).
- **C — Cardano path**: C1 quorum root acceptance; C2 kernel validity-verifier feasibility over Plutus V3 BLS primitives; C3 neutral forced-exit representation (G6). The kernel/simulation split makes C2 the interesting question; full-simulation verification is not asked of any candidate.
- **D — Arbitrum/Nitro path**: D1 stock app-chain commitments + DA + escape economics; D2 custom-STF spike: whether the kernel survives translation into the Nitro STF/replay model with acceptable single-source properties.
- **E — Generic zkVM kernel rollup (admitted by the kernel split)**: kernel validity proofs via a general zkVM with the simulation layer optimistic/replay-audited; feasibility spike before it earns full candidate status.

## 5. Eligibility and Selection

```
gate failure → candidate rejected or redesigned
all required gates passed → ADR-eligible
2+ eligible → comparative ADR: security assumptions, maturity, operational burden,
              external dependencies, cost curves, verification sovereignty,
              participant-verifiable settled state, escape/continuity guarantees,
              engineering ownership, migration risk
```

There is no ranking and no first-past-the-post. A failure-routing table may order **effort** (e.g. if Cartesi fails only DA economics, try alternate DA for the same machine before evaluating D2), and orders nothing else. The candidates' settlement layers are additionally evaluated against the succession and snapshot-pointer requirements (`verification.md` §8), which entered after the original candidate write-ups.

Participant-verifiable settled state asks whether a participant can independently obtain and verify the bounded canonical settlement state it relies on, via a practical direct read path, without trusting the game operator or a proprietary indexer (`architecture.md` §21: signing is delegable, reading is not). Record it at one of three levels, never as a yes: protocol possibility, a practical bounded client path, or operator and indexer dependency. Data being theoretically on chain is not the same as a lightweight participant querying the exact checkpoint, result and proof data it needs. Slice B shows the middle level is reachable on an EVM settlement layer: participants read the binding and settled outcome themselves over three pinned selectors, and the harness-written descriptor carries only bootstrap identifiers and endpoints anchored on chain anyway.

## 6. Candidate Notes (role view, no ranking)

| Property | Cartesi rollup | Avalanche L1 | Cardano settlement | Arbitrum/Nitro | zkVM kernel rollup |
|---|---|---|---|---|---|
| Canonical machine alignment | strong (single-source RISC-V) | must build | external/bespoke | moderate (custom STF) | kernel-scoped |
| Dispute machinery | Dave (young; measure) | none: build | none native | BoLD/Nitro (mature) | n/a (validity) |
| Validity path | zkVM over machine (open) | self-built | plausible for kernel via BLS primitives | possible, not native focus | native |
| Settlement neutrality | strong | own validators | strong | strong | depends on parent |
| DA for recovery | modular: investigate | must design explicitly | external | configurable | configurable |
| Status | prototype required | blocked pending verifier + DA design scope | prototype required (kernel-validity feasibility) | prototype required (STF translation) | spike required |

## 7. Deliverables

0. Slice B harness (§2): minimal settlement contract, Odin protocol probe, E2E script, negative paths, dual-process participant run, deterministic CI run.
1. Conformance suite (0a vectors + edge cases; 0b fuzz harness; conservation assertions; permanent CI asset).
2. Kernel prototype: permit reservation/consumption, assigned entropy, capture roll, capability accounting, authenticated tree; Transition 0 harness.
3. Written protocol spec sufficient for 0c, plus the independent replay tool (different engineer, no reference-source reuse).
4. Independent kernel implementation (0c).
5. Per-experiment measurement reports, gate by gate, raw numbers.
6. Cost model per §3 G7.
7. Comparative ADR draft, recorded only from measured results.
