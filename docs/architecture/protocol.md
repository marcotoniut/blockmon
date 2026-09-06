# Blockmon Protocol Semantics

| | |
|---|---|
| **Status** | **v0.2**, invariants frozen; items marked OPEN are the protocol-specification docket; battle-channel amendment 2026-09-01 |
| **Last reviewed** | 2026-09-01 |
| **Owns** | Canonical state/encoding, transition semantics, ordering and receipts, entropy, capabilities, finality, ordering policies, manifests, conservation, migration, checkpoints, exit semantics, envelopes |
| **Depends on** | `architecture.md` (invariants; not restated) |

This document must eventually contain everything an independent team needs to implement the kernel transition and replay tooling without asking architectural questions. Sections state REQUIRED semantics (frozen) and OPEN items (to be specified or deliberately deferred).

Vocabulary note, stated once: a **subject** is a protocol identity (a key), never a person; **player** is used only in product context. Human identity is out of protocol scope.

---

## 1. Canonical State

- WorldState decomposes into typed sub-states with canonical, versioned encodings. Ratified domains: **subject (player), Blockmon, encounter, supply/capability**. Marketplace and tournament domains are anticipated, unratified (register Q9).
- Sub-states hash into an authenticated state tree producing `world_root`. The settled artefact is conceptually `{world_root, protocol_manifest_hash, verification_manifest_hash, supply_commitment, epoch}`.
- Primitive/record encodings and the protocol hash (SHA-256 with length-prefixed domain separation) are **provisionally pinned** in `canonical-encoding.md`, exercised by the G0a corpus (`conformance/vectors/`), and replaceable via migration (§11). The hash choice is a ProtocolManifest field.
- OPEN (spec docket): authenticated state-tree structure (Transition 1 scope); canonical encodings for kernel objects beyond the battle-channel transcript set.

## 2. Transition Function and Determinism Contract

```
transition(prev_state, commands, entropy, protocol_manifest)
    -> { next_state, transcript }
```

REQUIRED:

- **Totality**: every syntactically valid sequenced command produces a defined outcome, including defined failure on unmet preconditions. Batch invalidity is never the answer to a bad command.
- **Determinism**: integer/fixed-point arithmetic only; canonical iteration order; canonical versioned encodings; defined overflow behaviour; seedable versioned RNG only; time only as canonical input; no allocator/platform behaviour influencing canonical output. Cross-target and cross-implementation conformance are gates, not aspirations.
- **Kernel step budget**: a per-transition bound (ProtocolManifest constant) so no valid transition can exhaust verifiers.
- The transcript is the ordered sub-transition record sufficient for replay and challenge; canonical transcript encoding is versioned.

## 3. Canonical Ordering

- The **canonical sequencing position** is the protocol's temporal primitive. Entropy assignment, capability reservation, epoch membership, manifest binding and finality are all positional predicates. Wall-clock time never decides protocol questions.
- **Epochs close at canonical positions.** "In-epoch" is decidable from the order alone.
- A **force-inclusion route** bounds censorship: a transaction ignored beyond the censorship bound becomes includable without sequencer cooperation, and exclusion is provable from receipts plus DA.

## 4. Sequencing Receipts (protocol-blocking specification)

A receipt is the sequencer's signed promise of a canonical position. REQUIRED properties:

- binds: position identifier, command/intent hash, authoring ProtocolManifest hash;
- carries a sequencer signature or equivalent proof of assignment;
- **equivocation is detectable**: two conflicting receipts for one position (or one command at two positions) constitute portable proof of fault, admissible in succession decisions and any bonding scheme;
- receipts order-compare deterministically;
- the receipt-to-input-finality path is defined: canonical order is fixed by DA publication; receipts are evidence, not finality;
- on conflicting receipts, the DA-published order governs; the holder of an unhonoured receipt is protected by force-inclusion.

OPEN: wire format, signature scheme, bonding. The properties above are frozen.

## 5. Entropy

REQUIRED semantics:

- **Ordering invariant** (`architecture.md` §9) is a mechanical validity rule over the canonical order.
- **Assignment rule**: the resolving round for a commitment is a pure function of its sequencing position (the first round whose reveal position may follow it, plus a fixed safety margin). Subjects never choose rounds; there is no request path; multiple attempts require multiple reserved capabilities.
- **Reveal availability**: once an action is bound to round `r`, canonical progression beyond the round's resolution deadline MUST make the authenticated value of `r` available to deterministic execution. No sequencer may selectively prevent resolution of an action whose assigned entropy is publicly available. Acceptable shapes (OPEN, choose at spec time): canonical reveal input; deterministic external round reference with proof; force-inclusion of the reveal by any party. A batch violating the deadline without making `r` available is invalid.
- **Resolution is reveal-free for the subject**: nothing remains for the subject to disclose after commitment; outcomes compute automatically from the published round.
- **Outage**: a halted source delays resolution; round indices are fixed at commitment, and a resumed source yields identical values: no reroll, ever. Permanent source failure routes to a manifest-versioned successor (register Q13); pending actions across a source succession is the one place resolution may require a governance act.
- **Domain separation**: seeds derive per domain from (assigned round value, commitment data, manifest); actual domains follow ratified game semantics.
- Sealed submission (e.g. timelock encryption to the assigned round) is the reference shape for simultaneous PvP resolved on the canonical path; it removes reveal steps and sequencer peeking. Channelised battles must resolve simultaneity and hidden information inside the channel; the mechanism is OPEN (`battle-channel.md` §7, register Q15/Q17/Q18). Until it is ratified, channel operations are strictly sequenced (`battle-channel.md` §4), which concedes last-mover information; rulesets whose fairness depends on simultaneity or hidden information may not be wagered in channels before Q15/Q17/Q18 close.
- Trust note: threshold collusion at the source breaks unpredictability silently (never bias); blast radius is bounded by capabilities and envelopes; dual-source mixing is optional hardening (Q14).

## 6. Capabilities: Reservation and Disposition

REQUIRED:

- **Reservation at commitment**: at its canonical commitment position, a capability, permit or nonce becomes unavailable to all competing transitions. No capability may be raced, duplicated, reused, or left ambiguously available after that position. Reservation is positional, so corrections and successor re-execution reproduce it identically.
- **Per-class disposition at resolution**: each capability class declares exactly one of: `consume` (success and failure both spend it), `burn-on-failure`, or `release-on-defined-failure` with explicit semantics.
- **Coupling rule (load-bearing)**: any capability gating an **entropy-bound** outcome MUST be consume-on-attempt. Releasing it on failure would convert retry into a reroll against fresh entropy. Encounter Permits and capture rights are therefore consume-on-attempt: confirmed, not incidental. Capabilities gating entropy-free transitions (e.g. escrow locks) may release on defined failure.
- Issuance capabilities are epoch-scoped and expire at epoch close (a canonical position); `minted = consumed + expired` holds as an accounting identity (§10).

## 7. Finality Ladder

| Level | Meaning | Reversal risk |
|---|---|---|
| **Predicted** | client-local | none claimed |
| **Sequenced** | signed receipt of position | sequencer equivocation (provable fault) |
| **Input-final** | inputs on DA, committed on parent | none; inputs are permanent |
| **Output-final** | claimed root survived the active acceptance rule | none within the stage's assumptions |

REQUIRED consumption matrix (minimum level per action class):

- own-subject gameplay (battles, progression, evolution): **Sequenced** (self-verifiable; the client computes the same function);
- cross-subject value interaction (trade, wagered battle settlement, breeding with another subject's creature, staked tournament entry): **Input-final**, at which point counterparties can verify claimed state themselves by replay. For a channelised battle the command is the dual-signed final checkpoint (`battle-channel.md` §5);
- external export, exit, prize withdrawal to external rails: **Output-final**.

Corrections: a successful challenge replaces claimed outputs by deterministic re-execution of the permanent input sequence; descendants re-derive through their defined-failure branches. Derived-view reconciliation semantics: `verification.md` §6.

## 8. Ordering-Policy Registry

Every economic transition class must register an ordering policy verifiable from canonical data (`architecture.md` §17). Current registrations:

| Class | Policy |
|---|---|
| P2P trade | bilateral signed intents (terms + expiry signed by both; ordering can delay, not alter) |
| Auction (if ratified) | sealed bids to a deadline round; deterministic resolution |
| Simultaneous PvP (canonical path) | sealed commands (§5) |
| Wagered battle settlement (channel) | dual-signed final checkpoint: a bilateral signed intent (ordering can delay, not alter); supersession by sequence (`battle-channel.md` §§4-5); limited to rulesets whose fairness does not depend on simultaneity or hidden information until Q15/Q17/Q18 close (§5) |
| Scarce registration (tournaments) | window + entropy lottery over valid entries |
| Scarce encounters | instanced per subject (no contended object) |
| Exits | not price-sensitive; censorship bound suffices |
| Open order book | **unregistered**; cannot be ratified without a batch-clearing policy |

## 9. Manifests

**ProtocolManifest** (what the game means): spec version; canonical encoding version; state-tree semantics incl. hash; RNG/entropy semantics and source binding; ruleset data; player-protection timing parameters; kernel step budget.

**VerificationManifest** (how correctness is adjudicated): machine artefact hash; proof/dispute protocol version; verifier implementation; verifier-internal timeouts.

REQUIRED rules:

- every settled commitment binds both hashes; transitions resolve under the ProtocolManifest active at their **commitment position**;
- commands/intents carry the ProtocolManifest hash they were authored against; sequencing under an incompatible manifest resolves to a **defined mismatch failure**, never a silent semantic switch;
- **conformance obligation**: any VerificationManifest change ships byte-exact transcript/root equality over the conformance corpus against the active ProtocolManifest; equality failure means it is a protocol change and takes the protected path;
- **safe-direction rule**: changes strictly tightening acceptance need no exit window; changes loosening acceptance or altering semantics/trust regime require notice and the protected path;
- historical commitments verify under the manifests active at acceptance; verifier upgrades never reinterpret old transitions;
- verification artefacts are reproducibly buildable: versioned source + pinned toolchain + recorded recipe → known artefact hash, third-party rebuildable.

## 10. Conservation Laws (normative)

Per epoch and capability class, over every reachable state:

```
scheduled envelope ≥ Σ minted capabilities         (checked at mint)
minted  = consumed + expired                       (identity at epoch close)
creations ≤ consumed                               (failed attempts waste; never mint)
extant  = created − exited; exactly one owner per extant Blockmon at every final root
escrowed value conserved across success and defined-failure branches
Σ distributed ≤ pre-committed pool, per reward pool
Σ tournament stakes = Σ prizes + declared rake
```

Retries, corrections, replay, succession, region reconciliation, capability expiry and duplicated inputs MUST NOT create value; each is covered by positional reservation and totality, and the conformance suite asserts these identities over fuzzed states. **Cross-platform agreement alone is insufficient: implementations can agree on an economically unsound transition.**

## 11. Migration Semantics

Any migration affecting canonical state representation (tree, hash, encoding) MUST preserve the declared conservation properties of the pre-migration state: unique ownership, creature and issuance accounting, conserved balances, escrow, capability accounting; except where the migration contains a separately authorised, explicit constitutional economic change. Old roots verify under old semantics; the migration transition itself is a canonical, replayable transition. OPEN: proof mechanism for preservation.

## 12. Checkpoints and Recovery Snapshots

REQUIRED:

- checkpoints derive **only from output-final roots**;
- a snapshot is full canonical state, canonically encoded, chunked, root-addressed; any party verifies any copy against the settlement-recorded checkpoint root; any party may re-serve it;
- the settlement layer records the latest checkpoint root and height: **freshness comes from settlement, content from mirrors, integrity from the root**;
- timing: `worst_case_challenge_resolution + checkpoint_publication_time + recovery_safety_margin < minimum_guaranteed_DA_retention`, equivalently: a final, independently retrievable recovery snapshot must exist before any incremental canonical data required to advance from the previous one can leave the guaranteed DA window;
- canonical inputs may prune after the challenge horizon once a subsequent checkpoint is output-final.

OPEN: chunk format (needed by the recovery drill; part of the spec docket).

## 13. Exit Semantics

REQUIRED:

- an **exit intent locks the asset at the intent's canonical position**; conflicting later transitions resolve to defined failure;
- external materialisation acts only on **output-final** state;
- **uniqueness of ownership/control across the exit boundary**: at no point may both an internal and an external representation be simultaneously spendable;
- exit authorisation is a signed message any party may relay and fund; exits are aggregatable (`architecture.md` §13).

OPEN: cancellation of an unmaterialised intent; concrete external representation (deliberately not a token/NFT mandate).

## 14. Envelope Semantics

Simulation-layer deltas enter the kernel only through declared envelopes carrying per-event bounds and per-subject-per-period rate/aggregate bounds; dual-signed channel results are simulation-layer deltas for this purpose. Out-of-envelope deltas resolve to defined rejection. Envelopes are blast-radius bounds, not correctness claims (`architecture.md` §4). OPEN: aggregate state-growth envelope (register Q12).

---

## Specification docket

Each item must be written before the first transition, gate or artefact that exercises it; nothing may be defined post hoc by reference-kernel behaviour, or G0c's independent implementation cannot reproduce it.

Satisfied for Transition 1 by `canonical-encoding.md` (provisional pins, conformance obligation §9 governs change): canonical encoding spec; kernel transition spec for the representative transition (capture roll and creation arithmetic, §6 there); entropy assignment constants; manifest field encodings; conformance vector format with conservation assertions.

Still unwritten, not exercised by Transition 1, and blocking on first use: reveal-availability mechanism choice (the kernel takes the authenticated round value as input); receipt format; finality state machine as written tables; checkpoint/snapshot chunk format. Everything else in this document marked OPEN is either deferred by design or an implementation choice.

Slice B (`prototype-and-technology.md` §2) does not wait for this docket: it needs only provisional channel operation/checkpoint/authorisation encodings, owned by `battle-channel.md` and pinned provisionally like any Gate 0 placeholder.
