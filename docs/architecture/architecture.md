# Blockmon System Architecture & Invariants

| | |
|---|---|
| **Status** | **v0.3 Frozen**, subject to falsification by the prototype gates (`prototype-and-technology.md`) |
| **Last reviewed** | 2026-08-11 |
| **Owns** | Durable cross-layer invariants, trust model, attack-ownership index, open-questions register |
| **Does not own** | Protocol semantics (`protocol.md`), physical/economic trust (`trust-and-economy.md`), verification and recovery mechanics (`verification.md`), gates and technology evaluation (`prototype-and-technology.md`) |

This document defines what Blockmon **is**, independent of blockchain, proof system, programming language, or infrastructure. Architecture exploration is closed; changes to this document require a demonstrated contradiction, security failure, economic failure, or infeasible requirement.

---

## 1. Purpose and Scope

Blockmon is an AR creature-collection game: players physically discover, capture, battle, breed and trade creatures ("Blockmon") whose existence, ownership and scarcity are constitutionally guaranteed rather than administratively asserted.

Guarantees (see §11 for what "ownership" precisely decomposes into):

- **Ownership**: provable against settled state using public data plus a player-held key.
- **Scarcity**: issuance bounded by a constitutional schedule no operator can silently violate.
- **Correctness**: economically meaningful transitions are, ultimately, independently verifiable by anyone.
- **Survivability**: constitutional state remains recoverable and continuable even if all operators disappear or turn adversarial.

Non-goals: on-chain gameplay execution; one chain transaction or NFT per creature or action; cryptographic proof of physical-world truth; proof of human agency behind commands; building consensus or networking from scratch.

## 2. Architectural Principles

1. **Gameplay first.** Player experience never blocks on chain latency or fees.
2. **Constitutional layer, never gameplay engine.** The constitutional layer refuses commitments, exits, issuance or ownership changes that cannot satisfy the active verification and economic rules. It never executes gameplay.
3. **Native deterministic execution.** All consensus-relevant computation runs natively, bit-for-bit reproducibly (contract in `protocol.md` §2).
4. **Verification independent of execution.** The acceptance rule for published roots evolves (authority, quorum, fraud proofs, validity proofs); the transition function does not.
5. **Replayability.** Every economically significant transition is reproducible from its canonical inputs alone.
6. **Aggregated settlement.** Settlement cost is sublinear in activity through aggregation. DA cost may scale with compressed information; per-player visible cost is zero or sponsored.
7. **Player-transparent infrastructure in normal operation.** Ordinary players pay no visible fees and hold no infrastructure role while operators are live. Emergency exit MAY expose standard chain interaction and MUST be executable by third parties on a player's behalf (exit authorisation is separable from fee payment).
8. **Protocol/language independence.** Protocol semantics are defined by the written specification and canonical vectors, not by any implementation. Odin is the reference implementation, which is an implementation fact.

## 3. System Decomposition

| Concern | Responsibility |
|---|---|
| **Client** | AR, rendering, input, local prediction; untrusted |
| **Constitutional kernel** | Value creation, ownership, supply, escrow, value-relevant randomness (§4) |
| **Deterministic simulation layer** | Battles and game logic feeding the kernel bounded deltas (§4) |
| **Discovery** | Converts physical presence into consumable authorisations (`trust-and-economy.md`) |
| **Sequencing** | Canonical order of inputs; receipts (`protocol.md` §§3-4) |
| **Data availability** | Canonical inputs publicly retrievable for the challenge horizon (§10) |
| **Verification** | Claimed roots follow from valid transitions (`verification.md`) |
| **Settlement** | Anchors constitutional state, issuance bounds, exit, checkpoints, succession |
| **Derived state** | Query views; never authoritative; root-addressed projections with retraction support (`verification.md` §6) |

## 4. Constitutional Kernel and Deterministic Simulation Layer

Membership rule:

> If dishonest computation or dishonest randomness can **create** new transferable economic value, that computation belongs in the constitutional kernel, or must be constrained by a constitutionally verified capability. Computation whose dishonesty can only **redistribute** an already constitutionally bounded amount may remain in the deterministic simulation layer, subject to replay and challenge.

- **Kernel**: capability/permit consumption, entropy binding and value-relevant rolls (capture creation, breeding-derived creation, lottery allocation), creation/transfer/supply arithmetic, escrow, envelope enforcement, per-transition step budget.
- **Simulation layer**: battles, per-turn logic, encounter behaviour, progression computation. Deterministic, canonically transcribed, replayable and challengeable. Its outputs enter the kernel only as **envelope-checked deltas**.
- **Envelopes are blast-radius bounds, not correctness proofs.** They carry per-event and per-subject-per-period (rate/aggregate) dimensions; a stream of individually legal maxima is itself bounded.

Guarantee ladder: kernel validity → simulation replay/fraud verification → economic envelopes → product/fairness policy. The kernel never claims to guarantee simulation correctness merely because outputs stayed inside bounds.

## 5. Canonical State and Transitions (shape)

Bounded public commitment over unbounded game state: typed sub-states hash into an authenticated tree whose root, together with manifest hashes and supply commitments, is the settled artefact. Transitions are **total functions**: every syntactically valid sequenced command produces a defined outcome, including defined failure. Semantics: `protocol.md` §§1-3.

## 6. Value-Creation Invariant

> No canonical transition creates or unlocks transferable economic value except by (a) consuming pre-existing constitutional value, (b) consuming a finite, pre-committed constitutional issuance capability, or (c) consuming a capped, authority-attributable authorisation across a named external trust boundary. No implicit mint path exists.

The Discovery Authority is currently the only (c) boundary. The full creation-authority matrix: `trust-and-economy.md` §6.

## 7. Issuance

Total issuance follows a **constitutional scheduled envelope**, changeable only via the protected upgrade path. Population and activity signals affect **distribution** (where and what spawns) strictly within the envelope; **no external oracle holds mint authority**. Finite issuance capabilities partition the envelope by class (capture, breeding, reward pools) and are pre-allocated per epoch (`trust-and-economy.md` §7), so regional execution needs no global mutable supply hot path.

## 8. Finality Separation

**Input finality and output finality are distinct.** Canonical inputs, once sequenced and published to DA, are permanent; verification disputes claimed *outputs*, never inputs. Corrections re-derive state by deterministic re-execution; they never erase inputs and never require manual repair. Finality ladder (Predicted, Sequenced, Input-final, Output-final) and the per-action consumption matrix: `protocol.md` §7.

## 9. Choice-Entropy Ordering

> Every economically consequential command (equivalently: every kernel-transition input) must occupy a canonical sequencing position strictly before the reveal position of any entropy influencing its outcome, mechanically checkable from the canonical order. Entropy is assigned by rule, never chosen. Failure to act resolves to a ruleset-defined default without fresh entropy; retry requires fresh scarce authorisation.

Consequence for game design, binding: **economically consequential actions are discrete, pause-tolerant events** with seconds-class resolution latency. Assignment and reveal-availability semantics: `protocol.md` §5.

## 10. Data Availability and Recovery Are Different Things

- **DA** is a bounded, recent availability window guaranteeing canonical inputs are retrievable for verification and challenge. Unavailable batches cannot finalise; DA failure is protocol-visible.
- **Recovery** rests on **output-final checkpoint snapshots**: full canonical state, canonically encoded, chunked and root-addressed, verifiable against the settlement-recorded checkpoint root by anyone, and re-servable by anyone. One honest mirror suffices.
- Timing invariant (full form `protocol.md` §12): a verified recovery snapshot must exist before any incremental data required to advance from the previous one can fall outside the guaranteed DA window.

## 11. Ownership Guarantees (decomposition)

"Constitutional ownership" is five guarantees with different trust:

| Guarantee | Depends on |
|---|---|
| **Prove** entitlement | public data + player key: operator-independent |
| **Exit** to external control | settlement liveness + player key (+ any relayer): operator-independent |
| **Recover** the world containing it | one honest mirror + settlement + spec + artefacts: operator-independent |
| **Use** it in play | a live operator or successor; bounded service gap during succession |
| **Transfer** it in-game | same as use |

Documents must not use the bare word "ownership" where the distinction matters.

## 12. Player Keys and Recovery Constraints

Players hold **non-custodial cryptographic authority** from launch; normal UX hides it entirely. Constraints (mechanism intentionally open):

- Key recovery MUST NOT depend on operator liveness.
- A recovery authority MUST NOT be able to seize assets from a still-valid key; recovery rotation takes effect only after a protected delay **at least the composed protected-path bound (§15)**, so the original key-holder can complete an escape first.
- Recovery claims are publicly and auditably committed.
- **No key of any kind can pause, delay or block exits.**

## 13. Continuity and Escape

- **Permissionless continuity (relaunch)** is the primary mass-survivability mechanism: recovery snapshot + DA-window inputs + written spec + reproducible artefacts let any party continue the system. Degraded mode is explicit: without a Discovery Authority, existing state and play continue; new issuance pauses until governance appoints a successor authority.
- **Succession**: permissionless constitutional continuation MUST be possible after objectively detectable committer failure, judged only from settlement-visible liveness. Requirements: `verification.md` §8.
- **Exits** MUST be individually executable, third-party relayable, and **aggregatable** (any party may batch many exit claims into one settlement action). Per-player settlement transactions as the only path is rejected as infeasible at scale.

## 14. Manifests

Protocol semantics and verification machinery version separately: **ProtocolManifest** (what the game means) and **VerificationManifest** (how correctness is adjudicated). Every settled commitment binds both hashes; commands bind the ProtocolManifest they were authored against. Rules that keep the split safe (conformance obligation, safe-direction rule, mismatch rule): `protocol.md` §9. Historical commitments remain interpretable and verifiable under the manifests active at acceptance; reproducible builds make the verification artefact independently rebuildable.

## 15. Clock Composition

Individually reasonable clocks must compose. Normative inequalities, all evaluated under the **pre-change** parameters, with timing parameters changeable only via the protected upgrade path:

```
upgrade_activation_delay ≥ censorship_bound + input_finality_delay
                         + adversarial_challenge_resolution
                         + adversarial_exit_execution + margin

worst_case_challenge_resolution + checkpoint_publication_time
                         + recovery_safety_margin
                         < minimum_guaranteed_DA_retention

key_recovery_rotation_delay ≥ the protected-path bound above
```

## 16. Privacy Minimisation

> Public constitutional and DA data expose no more physical or behavioural information than verification and recovery require.

Mechanisms (commitment-level issuance transparency, epoch-scoped pseudonyms, coarse encounter classes, retention horizons): `trust-and-economy.md` §9. Regulatory analysis is a separate legal workstream.

## 17. Ordering-Insensitivity of Economic Transitions

> Every economic transition class is ordering-insensitive within a declared window (uniform clearing, lottery, sealed or bilateral terms), or carries an explicit domain ordering policy verifiable from canonical data. A class without a registered policy cannot be ratified.

This collapses sequencer power over economics to inclusion, which the censorship bound governs. Registry: `protocol.md` §8.

## 18. Launch Minimum (Stage A)

Stage A (operator-verified outputs) may launch only with all of the following live: publicly committed state; independent DA with demonstrated third-party reconstruction; player-held keys; forced exit and force-inclusion; the constitutional issuance envelope enforced at settlement; manifests and upgrade timelock; at least one independent state mirror.

Honest Stage A claim: **inputs, ownership, scarcity bounds and escape are trustless; execution honesty is trusted and tamper-evident.** Stage A must never be marketed as trustless. Its residual trust is exactly output verification.

## 19. Trust Model

| Layer | Trust assumption | Can prove | Cannot prove | Failure visibility |
|---|---|---|---|---|
| **Discovery** | Authority honesty within caps | permit authorised, consumed once | physical assertions were true | audit, bounded by caps |
| **Entropy** | threshold non-collusion (unpredictability); liveness | value correct for round, unbiased | that no insider pre-knew it | **silent** (collusion), visible (halt) |
| **Sequencing** | committer liveness/honesty pre-succession | canonical order existed | order was extraction-free beyond registered policies | receipts, equivocation proofs |
| **Execution** | none once verified; operator honesty at Stage A | state follows from inputs under manifests | inputs honestly gathered | stage-dependent |
| **DA** | availability within window | data published | anything about withheld data | protocol-visible |
| **Verification** | stage/mode-dependent | claimed roots valid | anything about withheld data | challenge record |
| **Settlement** | settlement chain security | issuance bounds, exit, checkpoints, succession | correctness it did not verify | chain-visible |

Worst-case insider composite (Discovery Authority + sequencer + entropy threshold): still bounded to pre-allocated epoch issuance. That bound is the design's last line, and it holds.

## 20. Attack-Ownership Index

| Attack class | Invariant | Owner |
|---|---|---|
| Replay/duplication | single reservation per canonical position; nonces | `protocol.md` §6 |
| Choice after entropy; reroll; multi-draw | §9; assignment rule; burn-on-attempt | `protocol.md` §5-6 |
| Reveal withholding | reveal availability rule | `protocol.md` §5 |
| Forged outputs; laundering | finality separation; counterparty replay | `protocol.md` §7, `verification.md` §§5-6 |
| Envelope-legal corruption | kernel membership rule; rate envelopes | §4, `protocol.md` §14 |
| Supply attacks (regional, breeding, Sybil, authority compromise) | envelope + capability partition; caps | `trust-and-economy.md` §§6-8, §11 |
| Withholding/DA | no finality without availability | `verification.md` §7 |
| Censorship; sequencer extraction | force-inclusion; §17 registry | `protocol.md` §§3-4, 8 |
| Governance/upgrade abuse; version confusion | §§14-15; manifest binding | `protocol.md` §9 |
| Migration mint/burn | conservation preservation | `protocol.md` §§10-11 |
| Recovery attacks (stale mirror, hostile succession, returning operator) | settlement pointer; succession rules | `verification.md` §8 |
| Exit races | position-locked exit intent | `protocol.md` §13 |
| Key recovery abuse | §12 constraints | §12 |
| Sponsored-fee exhaustion | bounded authorisations, rate limits, sponsor budgets | `trust-and-economy.md` §10 |
| Privacy/linkage | §16 | `trust-and-economy.md` §9 |

---

## Appendix: Open-Questions Register (authoritative, single copy)

Product/protocol questions intentionally unresolved. No other document may restate these as gaps.

| # | Question | Layer | Blocking what |
|---|---|---|---|
| Q1 | Entropy reveal-availability mechanism (canonical input vs referenced proof vs force-inclusion shape) | protocol | production mechanism only; invariant frozen |
| Q2 | Forfeit/default-outcome severity calibration for unsubmitted actions | ruleset | game design |
| Q3 | Key-recovery mechanism (constraints frozen in §12) | product/protocol | production custody design |
| Q4 | Succession election algorithm and bonding (requirements frozen) | settlement design | per-candidate prototype |
| Q5 | Governance: who proposes/approves upgrades and successor authorities | governance | not prototype-blocking |
| Q6 | Anti-Sybil distribution fairness within the envelope | trust-and-economy | product policy |
| Q7 | Witness/beacon evidence classes and collusion resistance | trust-and-economy | later evidence upgrades |
| Q8 | Breeding capability allocation and genetics semantics | ruleset | game design |
| Q9 | Marketplace/tournament state domains (unratified) | protocol | game design ratification |
| Q10 | Batch posting cadence vs trade-latency vs DA-cost trade-off | product/infra | Gate 8 measurement |
| Q11 | Odin toolchain reproducible-build feasibility | tooling | Gate 0d |
| Q12 | Aggregate state-growth envelope (beyond per-transition step budget) | protocol | Gate measurement |
| Q13 | Entropy-source successor procedure detail on permanent beacon failure | protocol/governance | rare-event runbook |
| Q14 | Dual-beacon mixing as hardening against threshold collusion | protocol | optional hardening |
