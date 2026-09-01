# Blockmon Trust & Economy

| | |
|---|---|
| **Status** | **v0.3**, boundaries and requirements stable; mechanisms marked provisional inline; battle-channel amendment 2026-09-01 |
| **Last reviewed** | 2026-09-01 |
| **Owns** | Physical truth boundary, Discovery Authority, permit lifecycle, value-creation matrix, issuance envelope and capabilities, privacy, participation/automation residuals, sponsored-fee exhaustion, physical/economic attack model |
| **Depends on** | `architecture.md` §§6-7, 16 and `protocol.md` §§5-6 (not restated) |

**Key invariant of this document:**

> Cryptographic verification can prove that Blockmon correctly processed an authorised action. It cannot prove that the physical-world assertions behind the authorisation were true, nor that a human chose the commands. Both limits are permanent; the design bounds their blast radius instead of denying them.

---

## 1. Physical Truth vs Protocol Truth

Protocol truth begins at the authorisation. Everything before it (GPS, sensors, device integrity, human agency) is evidence evaluated off-chain by an accountable authority; everything after it is deterministic and verifiable. The evidence-to-authorisation boundary is kept narrow, auditable and replaceable because it is the one boundary proofs cannot cross.

## 2. Encounter Lifecycle and Permit

```
fresh challenge (bound to claim context) → evidence → Discovery Authority
    → signed EncounterPermit | rejection
    → permit committed (reserved at canonical position; consume-on-attempt)
    → entropy assigned by rule → deterministic capture roll (kernel)
    → creature enters canonical state, consuming a capture-class capability
```

Permit shape (conceptual, not wire format): subject, encounter class, policy, expiry, nonce, authority id, signature(s). Properties: single-reservation, expiring, bound to a subject, auditable, containing **no raw location data**. Discovery establishes eligibility; creation is a kernel outcome.

## 3. Discovery Authority

The system's dominant trust concentration and the only named external value-creation boundary. Requirements:

- **Replaceable**: the protocol depends only on permit format and authority keys, never on an evidence mechanism.
- **Bounded**: authorities issue against pre-allocated, epoch-scoped capability allocations (§7); a fully compromised authority cannot exceed its allocation. Caps are structural, not policy.
- **Accountable**: issuance publicly auditable at commitment level (§9), credentials rotatable prospectively; permits already issued under a compromised credential are an open incident-response policy that must never silently rewrite finalised history.
- Multi-authority structures (threshold issuance, evidence-class separation, regional authorities under global caps): provisional hardening directions.
- Staking/slashing remains a candidate only, pending an objective adjudication predicate.

## 4. Evidence Classes

GNSS is client-reported and cheaply forged; a decade of location-game history makes spoofing the dominant persistent attack. Evidence is layered, none individually sufficient: platform attestation (device/app integrity, feeds rate limits; farms of genuine devices remain possible), fresh challenges bound to claim context (defeats replay and transplantation), later beacons/witnesses/proof-of-location networks (witness collusion is the central unsolved problem of any witness system: register Q7). Each layer raises attacker cost per forged permit; caps bound what forgery can yield.

## 5. Audit

Statistical (issuance patterns vs plausible movement), cross-evidence (gameplay contradicting issuance context), and challenge-based (re-attestation before unrestricted transferability) auditing operate on authority-side private data plus public commitments.

Audit consequences respect three distinct properties: **finality of existence/ownership ≠ trade eligibility ≠ risk classification**. Audit never un-captures a finalised creature; it may (provisionally) gate transferability timing and risk classification, and it feeds accountability.

## 6. Value-Creation Matrix

The three-shape invariant (`architecture.md` §6) instantiated; this table is exhaustive and any new path must be classified before ratification:

| Path | Shape | External assertion? |
|---|---|---|
| Capture | (c) permit + (b) capture-class capability | **yes: the only one** |
| Breeding | (a) two owned parents + (b) breeding-class capability | no |
| Progression reward, non-transferable | envelope-bounded simulation delta; no issuance | no |
| Progression reward, transferable | (b) pre-committed epoch reward pool, deterministic distribution | no |
| Tournament reward | (a) escrowed stakes: results dual-authorised (channel) or fraud-provable; (b) pre-committed pool: results fraud-provable only, since dual authorisation cannot gate third-party funds, two colluding participants would drain the pool (`battle-channel.md` §7 blast radius) | no |
| Market incentive | (b) pre-committed pool | no |
| Future event reward | (b) allocation from the envelope via protected upgrade path | no |

There is no Participation Authority. External authority exists only where an external-world fact must cross into protocol truth.

## 7. Issuance Envelope and Capabilities

```
constitutional scheduled envelope (per epoch; protected-path changes only)
    ↓ minted ahead of use (kernel-checked against envelope)
epoch-scoped issuance capabilities (region × authority × class)
    ↓ reserved at commitment, consume-on-attempt for entropy-bound classes
regional execution (disjoint within epoch)
    ↓ epoch close (canonical position)
reconciliation; unconsumed capabilities expire
```

- Population/activity signals shape **distribution** (spawn density, regional weighting) inside the envelope; totals never move with them, and no oracle holds mint authority.
- Breeding is a separate class: breeding cannot starve capture supply, nor vice versa.
- Rebalancing is by expiry and next-epoch allocation; there is no live cross-region transfer path.
- Evolution is a canonical transition wherever it affects economically meaningful state; whether it constitutes new supply is undesigned (register Q8).

## 8. Participation and Automation

A deterministic verifier can establish that commands were legal; it cannot establish that a human chose them. Consequences:

- Bots cannot mint: all value creation flows through §6's shapes, and capped pools bound what farming extracts.
- Bots within budgets are a **fairness and product problem**: distribution-share farming of capped pools is the residual (register Q6). Controls are authority-side rate limits, attestation signals, and product design; all probabilistic, never protocol truth.
- Systems creating no transferable value may tolerate automation freely.

## 9. Privacy and Minimisation

Instantiating `architecture.md` §16:

- **Commitment-level issuance transparency**: permit commitments (hash, authority, epoch, class) publish at issuance; over-issuance audit needs counts per authority, which commitments provide. Full permits reveal on consumption or audit sampling. Silent issuance stays impossible; the location feed does not exist.
- Subject identifiers in public data are epoch-scoped pseudonyms, linkable across epochs only by the key-holder.
- Location appears publicly only as coarse encounter classes; behavioural audit runs on authority-side private data.
- Retention: canonical inputs prune after the challenge horizon behind an output-final checkpoint (`protocol.md` §12).
- Regulatory analysis (erasure rights vs immutability; chance-based capture mechanics) is a separate legal workstream, flagged, not architecture.

## 10. Sponsored-Fee Exhaustion

Players pay nothing in normal operation, so every canonical action spends operator money on DA and settlement. Valid-but-abusive activity within attestation rate limits is therefore an economic DoS on the sponsor. Owner: this document. Controls: bounded authorisations for value-bearing actions, per-attested-identity rate limits, sponsor budgets with degradation policies, admission policy. Player-visible fees are **not** the default mitigation. Per-action sponsor cost is a prototype measurement (Gate 7).

## 11. Economic Attack Model (physical/economic layer)

Protocol-layer attacks are owned by `architecture.md` §20; this table owns what valid cryptography cannot detect.

| Attack | Vector | Containment |
|---|---|---|
| Location forgery | spoofing, replay, farms of attested devices | §4 layers; §5 audit; §7 caps bound yield |
| Authority compromise/coercion | keys, insider, legal pressure | §3 structural caps; §9 issuance transparency; prospective rotation |
| Distribution gaming (Sybil/bots) | fake activity skews spawn/reward distribution | totals immune (§7); fairness residual (§8, Q6) |
| Issuance timing games | timing permits vs entropy or upgrades | assignment rule; consume-on-attempt; upgrade protections |
| Creation-path loops | breeding/evolution edge cases | every path in §6's matrix; class separation; balance fuzzing |
| Laundering flagged assets | trades before audit completes | transferability gates (provisional); lineage traceability; input-final counterparty replay |
| Sponsor exhaustion | §10 | §10 controls |
| Insider composite | authority + sequencer + entropy threshold | bounded to pre-allocated epoch issuance; the design's stated worst case |

Residual truth, stated plainly: a sufficiently capable attacker may obtain a permit on deceptive evidence, and cryptography cannot recover the missing physical truth afterwards. The architecture answers with layered evidence, structurally bounded issuance, commitment-level transparency, and containment that never silently rewrites finalised history.
