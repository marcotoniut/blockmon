# Blockmon Battle Channels

| | |
|---|---|
| **Status** | **v0.2**, properties marked REQUIRED frozen; mechanisms marked OPEN or provisional inline; 2026-09-01 additions: participant chain reading (§§2-3), incremental legality (§4), settled state recorded (§5) |
| **Last reviewed** | 2026-09-01 |
| **Owns** | Battle-channel cryptography (key hierarchy, session-secret establishment, domain separation), channel operation semantics (transcript, checkpoints, hidden information), channel settlement interface, disconnect/timeout/dispute model, channel attack model |
| **Depends on** | `architecture.md` §§4, 9, 21; `protocol.md` §§7-8, 14; `trust-and-economy.md` §6 (not restated) |

A battle channel is a bilateral off-chain execution venue for the deterministic simulation layer: heavy battle logic runs on the two participants' clients, and in the cooperative case only a compact, mutually authorised result reaches the rest of the system.

---

## 1. Position in the Architecture

- **Membership rule compliance** (`architecture.md` §4): a wagered battle redistributes escrowed, constitutionally bounded value and creates none, so it may execute outside the canonical sequencing path. Channel results enter the kernel as envelope-checked deltas like any simulation output.
- **Trust shape**: the cooperative close is a bilateral signed intent, the same shape as a P2P trade (`protocol.md` §8). Mutual signature replaces public replay; the dispute path restores replayability when consent fails.
- **Anchor venue**, REQUIRED: in the production architecture, battles are anchored (opened, key-registered, settled) in the **canonical constitutional layer**, so channel settlement inherits aggregation and fee sponsorship. Per-battle transactions on the settlement chain would violate aggregated settlement (`architecture.md` §2.6) and the no-per-action-transaction non-goal (§1). The prototype slice anchors battles directly in a minimal settlement contract as an explicitly declared stand-in for the canonical layer (`prototype-and-technology.md` §2).

## 2. Key Hierarchy

Three kinds of key material, never conflated (`architecture.md` §21):

| Material | Lifetime | Kind | Purpose |
|---|---|---|---|
| **Wallet identity key** | long-lived | chain-determined (settlement interface) | subject identity; authorises ephemeral battle keys; signs at the settlement boundary where required |
| **Ephemeral battle keypair** | one battle | protocol-chosen asymmetric | authenticates channel operations; DH input |
| **Battle session secret** | one battle | symmetric, derived | source of purpose-specific channel keys |

Terminology, REQUIRED: the symmetric secret is the **battle session secret** (or battle shared secret), never a "private key". "Private key" is reserved for the private half of an asymmetric pair.

REQUIRED: neither the deterministic kernel nor the channel protocol ever handles wallet private keys. Wallet signing sits behind the settlement adapter and may be delegated to an external signer (`prototype-and-technology.md` §2.2). Delegation stops at signing (`architecture.md` §21): a participant MUST be able to read the anchor venue's record of its own battle, and MUST NOT depend on another party's report of it.

## 3. Session-Secret Establishment

Reference shape; the listed properties are REQUIRED, the concrete primitives provisional:

1. Each participant locally generates an ephemeral battle keypair.
2. Each participant authorises their ephemeral battle public key with their wallet identity. The authorisation MUST bind at minimum: battle id, the ephemeral public key, the ruleset/ProtocolManifest hash, and an expiry. An unbound authorisation is replayable into battles the wallet never intended.
3. The anchor venue records: battle id, participants, authorised ephemeral public keys, ruleset/version binding, and any required public commitments (stakes, hidden-state commitments).
4. Both participants derive the same session secret locally through an authenticated Diffie-Hellman exchange over the anchored keys:

```
A computes dh = DH(skA, pkB)          B computes dh = DH(skB, pkA)

K_battle = KDF(dh, battle_id, protocol context, optional anchored entropy)
```

REQUIRED properties:

- the anchor venue and all third parties learn only public coordination data, never `K_battle`;
- authentication comes from wallet-authorised anchoring: a key that is not anchored cannot participate;
- each participant reads the anchored record itself before treating the battle as joined, and checks at minimum the ruleset/manifest binding and both ephemeral public keys against it. A battle description handed over by any other party is a joining instruction, never evidence;
- repeated battles between the same participants yield distinct secrets (fresh ephemerals plus the battle id in the KDF);
- purpose-specific keys derive from `K_battle` under explicit domain separation (transport encryption, hidden-state encryption, ...); the raw secret is never used directly for any purpose.

Retention, REQUIRED: secret material follows the battle lifecycle:

```
active battle → closed but challengeable → finalised → destroy dispute-required secrets
```

Transport keys MAY be discarded at close. Keys protecting **committed hidden state** MUST remain recoverable by their owner while the battle is challengeable; discarding them at close would make committed evidence unreadable exactly when a dispute needs it. At finalisation, everything is destroyed.

Provisional instantiation (implementation note, not architecture): X25519 + HKDF for the exchange and derivation, Ed25519 for channel signatures, an AEAD for encryption. All are settlement-independent; none requires chain-native primitives.

Scope note, REQUIRED reading for anyone extending this: a single shared session secret is a session-secret demonstration, not the hidden-information protocol. Battle mechanics may require per-player encryption layers, commitments, verifiable shuffles, or selective revelation (mental-poker-class constructions). That protocol is deliberately unresolved (registers Q15, Q17, Q18); a successful Slice B proves secret establishment and the settlement boundary, nothing more.

## 4. Channel Operation Semantics

REQUIRED:

- Every operation is signed by its author's ephemeral battle key. **A signature proves authorship and authorisation, never legality relative to hidden state.**
- Hidden-state legality rests on commitments plus one of: later reveal; dispute evidence; eventually zero-knowledge proofs. No signature scheme substitutes for this.
- A participant MUST locally validate every operation against all rules and state available to it before advancing its transcript. Where legality depends on counterparty-hidden state, the protocol MUST provide sufficient commitment/reveal, dispute evidence or proof machinery to establish that legality at the earliest protocol stage defined by the ruleset. Deferring all legality to the close conforms only for a ruleset with no hidden state; otherwise a dishonest or incompatible peer spends an entire battle before disagreement becomes visible. Which mechanism is OPEN (§9); that an adequate one must exist before such a ruleset ships is not.
- Operations form a hash-chained transcript: each carries the battle id, a strictly monotone sequence number, the hash of its predecessor, and the author's signature. Later operations MAY implicitly acknowledge earlier ones. The canonical byte encoding of operations and checkpoints, and their domain-separated hashes, are normative in `canonical-encoding.md` §4.
- Periodic **dual-signed checkpoints** commit a transcript position and state commitment, compressing history. Supersession is explicit: the highest-sequence dual-signed checkpoint governs, and implicit acknowledgement never weakens that precedence.
- Cooperative close is a compact final dual-signed checkpoint/result. The full transcript is dispute evidence held by the participants; it is never replayed at the anchor venue on the cooperative path.

## 5. Settlement Interface

The settlement-side verifier is deliberately thin. The cooperative path verifies only:

- battle existence and participants;
- battle/version/ruleset binding;
- final checkpoint/result well-formedness;
- participant authorisations and signatures;
- replay/sequence protection (supersession);
- non-duplication of settlement per battle id.

The recorded outcome MUST identify the state it came from: the accepted final checkpoint's state commitment is stored alongside the result, so a participant reading the record binds it to its own transcript instead of to a bare win/lose flag.

The verifier is implemented in the anchor venue's native environment; for an EVM candidate that is Solidity, with small Yul/assembly sections only where justified. It is never implemented in the kernel language, and the battle simulator is never ported into a contract for the prototype.

Cost targets: cooperative settlement O(1) at the anchor venue (and aggregated before reaching the settlement chain, per §1); disputed settlement proportional to the disputed work where possible; future validity settlement verifies one compact proof.

## 6. Disconnects, Timeouts, Disputes

REQUIRED: the protocol never attempts to distinguish a malicious disconnect from network failure. Non-response is handled by deadlines: a channel silent past its deadline resolves through the timeout path from the highest-sequence dual-signed checkpoint (or the anchored opening state if none exists), after a response window in which the counterparty may present a higher-sequence dual-signed checkpoint. Outcome severity for the non-responder is ruleset policy (the same calibration question as `architecture.md` register Q2).

Dispute sophistication beyond this (transition proofs, zkVM adjudication of a disputed step) is deliberately deferred (register Q16). The first implementation needs exactly: invalid-signature rejection, stale-checkpoint supersession, duplicate-settlement rejection, timeout settlement.

## 7. Entropy Inside Channels

Constitutional choice-entropy ordering (`architecture.md` §9) governs kernel-transition inputs; a dual-signed result satisfies it by construction, since no entropy influences the settlement command's outcome after both signatures exist. Fairness of randomness *inside* a channel is a bilateral concern whose blast radius is the escrowed stakes of two consenting participants. The mechanism (mutual commit-reveal per roll, a seed from anchored entropy, or both) is OPEN, register Q15. The prototype slice uses a deterministic test seed.

## 8. Attack Model (channel scope)

| Attack | Containment |
|---|---|
| Settling a stale checkpoint | supersession rule; response window (§§4, 6) |
| Duplicate settlement | per-battle-id non-duplication at the verifier (§5) |
| Authorisation replay across battles | authorisation binds battle id + ruleset + expiry (§3) |
| Hidden-state cheating | commitments + reveal/dispute/ZK; never signatures (§4) |
| Counterparty abort/griefing | deadlines and timeout settlement; no malice inference (§6) |
| Session-secret leakage | per-battle ephemerals bound blast radius to one battle |
| Result forged by one party | any settling checkpoint requires both signatures (§§4-5) |
| Misreported settlement to a participant | the participant reads the anchor venue itself; reports are never evidence (§§2-3) |

Protocol-layer and physical/economic attacks remain owned by `architecture.md` §20 and `trust-and-economy.md` §11.

## 9. Deliberately Undecided

ZK proof system, zk-friendly hash, dispute engine depth, checkpoint cadence/compression policy (registers Q15-Q18 in `architecture.md`). No specific mechanism is required by a frozen invariant, though §4 requires that an adequate hidden-state legality mechanism exist before a ruleset with hidden state ships. None blocks the prototype slice.
