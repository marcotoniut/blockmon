# G0c Report: Independent Cleanroom Re-implementation (Rust)

Verbatim report of the isolated implementing session, 2026-09-01. Inputs
exposed to the implementer: `docs/architecture/canonical-encoding.md`,
`docs/architecture/protocol.md`, `conformance/vectors/g0a-vectors.json`.
Nothing else, and explicitly no `protocol/`, `conformance/gen/`,
`conformance/fuzz/` or `check.py`.

---

## RESULT: PASS

- Vectors reproduced: **47/47** (25 primitive/composite encodes, 2 ambiguity-pair encodes with hashes, 4 domain-hash vectors, 2 op encodes, 2 transcripts, 1 checkpoint, 1 state, 3 transitions, 7 rejections)
- Distinctness pairs verified: **4/4** (ambiguity pair, domain separation, boundary shift, transcript ordering)
- Rejection vectors rejected: **7/7**
- Transition 1 vectors independently reproduced: **3/3** (success, roll-failed, rejected-expired). For each, the checker computes manifest bytes/hash, input world bytes/root, command bytes/hash, seed, roll, output state, output root, effects bytes, and transcript hash purely from the vector's inputs; expected outputs are used only for comparison. Nearly everything passed on the first compile+run; no vector-driven debugging of encoding or hashing was needed.

## SPEC FINDINGS

1. **Reject-reason enum discriminants are unassigned — vector-consulted.** canonical-encoding.md §6 declares `reject_reason: optional<enum>, // present iff REJECTED` but never names the enum or assigns values, while §4/§6 assign explicit values to every other enum. The rejected vector implies expired-permit = **5**. I had to take 5 from the vector; values 1-4 in my implementation (unknown subject, unknown permit, subject mismatch, not reserved) are provisional guesses untested by the corpus. This is the only place the vectors entered the computation path.

2. **The precondition set for Transition 1 is not enumerated — spec-only, untested.** protocol.md §6 and canonical-encoding.md §6 establish consume-on-attempt and that "precondition failures are defined rejections that consume nothing", but no list says which checks exist or their order (does an unknown subject reject? must permit.subject equal command.subject?). Only expiry is exercised by a vector. An independent implementation can diverge on any untested rejection path and still pass G0a.

3. **The kernel input context shape is not specified — harness-level.** protocol.md §2 gives `transition(prev_state, commands, entropy, protocol_manifest)`; the derivations reference `entropy_value` and position `p`, but the concrete input record `{position, epoch, entropy_round, entropy_value}` exists only in the vector file's schema. Related: whether the kernel must validate `entropy_round == assigned_round(position)` or `epoch == supply.epoch` is unstated. I validate the round as a boundary input error (holds in all vectors) and leave epoch unchecked.

4. **Supply field types rely on grouped-declaration convention — spec-only, confirmed.** `Supply := record { epoch, envelope, minted, consumed, created: u64 }` annotates only the last field. I read it as all-u64 (Odin/Go style); the vectors' 40-byte supply encoding confirms it. Worth spelling out in the spec.

Everything else — endianness, length prefixes, optional/seq distinction, trailing-byte rejection, domain construction, transcript chaining, expiry exclusivity ("canonical positions, exclusive" → reject at position == expiry, confirmed by the vector at 100/100), seed payload layout, roll arithmetic, effects presence rules, sorted insertion of the created Blockmon — was unambiguous from the two documents alone.

## IMPLEMENTATION NOTES

- Hash: SHA-256, `ProtocolHash(domain, payload) = SHA-256(u8(len(domain)) ‖ domain ‖ payload)`, domain 1-255 bytes printable lowercase ASCII ending `/v<decimal>` (asserted). Domains used: `blockmon/{op,checkpoint,state,world,manifest,capture-cmd,transition,creature-id,capture-roll}/v0`.
- Capture: `seed = H("blockmon/capture-roll/v0", entropy_value ‖ permit_id ‖ manifest_hash)`; `roll = u64_be(seed[0..8]) mod 10000`; success iff `roll < catch_rate_bp`; `creature_id = H("blockmon/creature-id/v0", permit_id)`; consume-on-attempt (permit → CONSUMED and `consumed += 1` on both success and roll-failure; rejection touches nothing).
- Strict decoder rejects: bool > 1, unassigned enum discriminants (incl. 0), invalid UTF-8, truncated lengths, optional flag > 1, and trailing bytes at top level.
- Dependencies: `sha2` 0.10, `serde_json` 1, `hex` 0.4.
- Files: `impl/src/enc.rs` (encoding/decoding/hash), `impl/src/kernel.rs` (T1 objects + transition), `impl/src/main.rs` (vector checker).

---

# G0c Pass 2: Re-derivation from the Amended Spec

The spec was amended to close pass 1's findings (`docs/architecture`
commits `2efe561`, `068e50d`). A second isolated session, same rules,
received the amended spec plus both corpora and updated the implementation
from the prose alone. Verbatim reports of that session follow.

## Main report

Both corpora pass and the gate is green.

### RESULT

| Corpus | Checks | Result |
|---|---|---|
| `vectors/g0a-vectors.json` (seed) | **51/51 PASS** (47 vectors incl. 3 T1 transitions + 7 rejections, plus 4 distinctness pairs) | PASS |
| `vectors/g0a-expansion.json` | **1019/1019 PASS** (501 encode, 198 rejections, 80 hash, 32 transcripts, 208 T1 transitions covering all nine reject reasons) | PASS |

Quality gate: `cargo fmt --check` and `cargo clippy --quiet --all-targets` (pedantic+nursery as errors) both clean. Conservation identities from protocol.md §10 are asserted on every computed transition (rejection leaves state byte-identical; an attempt consumes exactly one capability and one permit; failed attempts never mint; `created ≤ consumed ≤ minted ≤ envelope` post-state; output canonical/unique creature ids) — all hold.

### DIVERGENCES CORRECTED (first pass → amended spec)

1. **Swapped discriminants**: first pass had `PERMIT_SUBJECT_MISMATCH = 3`, `PERMIT_NOT_RESERVED = 4`. §6 assigns `PERMIT_NOT_RESERVED = 3`, `WRONG_SUBJECT = 4`. (`PERMIT_EXPIRED = 5` happened to match.)
2. **Wrong evaluation order**: first pass checked subject mismatch before reservation status; the normative order is `PERMIT_NOT_RESERVED` then `WRONG_SUBJECT`. Both the values and the order changed.
3. **Missing check, `WRONG_EPOCH` (8)**: `context.epoch` was carried but explicitly unused ("whether the kernel must cross-check epoch ... is unspecified"). Now checked against `supply.epoch`, second in order.
4. **Missing check, `NO_CAPABILITY` (6)**: `supply.consumed ≥ supply.minted` was never checked; a capture could proceed with no minted capability. Now checked last, per §6.
5. **Misclassified boundary errors → rejections**: entropy-round mismatch (was `InputError`, now `ENTROPY_MISMATCH = 7`), non-canonical world and `round_period = 0` (were `InputError`, now `INVALID_STATE = 9`). The `InputError` type is deleted; `transition1` is now total and infallible per protocol.md §2.
6. **New `INVALID_STATE` component**: a supply with `created > consumed` (violating §10 "creations ≤ consumed", which holds over every reachable state) is malformed boundary input caught by the totality guard. First pass had no supply validation.
7. **Provisional comment removed**: "Value 5 ... comes from the published vectors ... the others are this implementation's own provisional assignment" replaced by "RejectReason discriminants as assigned by canonical-encoding.md §6."

Checker extensions: six new composite value types derived compositionally from §2 (`seq:string`, `seq:bytes`, `seq:seq:u64`, `optional:string`, `optional:seq:u64`, `seq:optional:u64`) with strict-decode round-trips; explicit `reject_reason` comparison; multi-file CLI with per-file totals and one overall RESULT line, nonzero exit on any failure.

### SPEC FINDINGS

1. **`INVALID_STATE`'s supply clause is not in §6's prose.** §6 defined INVALID_STATE as "world fails the canonical form above, or the manifest is invalid (round_period = 0)", and "the canonical form above" names only sortedness. Yet all 13 expansion INVALID_STATE vectors are sorted, valid-enum worlds whose only defect is `created > consumed`. The reading is groundable — §6 calls reason 9 "the kernel's totality guard for invalid boundary input (malformed state or manifest), which canonical execution never produces", and §10's "creations ≤ consumed" is normative over every reachable state — but the prose alone underdetermined **which** §10 identities the guard evaluates. §6 should say explicitly that supply accounting is part of valid kernel input.
2. **Residual contradiction on `round_period = 0`**: the ManifestV0 comment said it is "rejected at the boundary in the same class as invalid state, never a crash and **never a protocol outcome**", while the normative precondition paragraph makes it INVALID_STATE surfacing as the REJECTED outcome. I followed the normative paragraph. No vector exercises `round_period = 0` (0 occurrences), so this stays untested.

### Value-sourcing confirmation

Every constant is now spec-cited: the nine RejectReason discriminants, outcome and status enums, evaluation order, roll arithmetic (`mod 10000`, `roll < catch_rate_bp`), `assigned_round`, all domain strings, and encodings. **One declared exception**: the *scope* of the INVALID_STATE supply guard (exactly `created ≤ consumed`, no more) was disambiguated by the vector corpus where the prose underdetermined it — the identity itself is spec text (protocol.md §10), and this is finding 1 above. No byte value was reverse-engineered from vectors.

## Follow-up after the second spec amendment

Both findings above led to further amendments (the INVALID_STATE row now
defines valid kernel input completely; the ManifestV0 comment is aligned).
The session re-derived and reported:

### What changed

`impl/src/kernel.rs`, `invalid_state` only. Re-derived from the amended §6 INVALID_STATE row, which now defines valid kernel input completely:

- **canonical form** (unchanged: subjects/blockmon/permits strictly ascending byte-lexicographically);
- **every enum field holds an assigned value** — new: each permit's `encounter_class` = COMMON(1) and `status` ∈ {RESERVED(1), CONSUMED(2)}, the only enum fields WorldV0 contains;
- **full supply chain** `created ≤ consumed ≤ minted ≤ envelope` (spec now cites protocol.md §10 itself) — widened from the previous `created ≤ consumed` only. My earlier inference that `consumed > minted` could not be INVALID_STATE is retracted per the amendment: the guard runs first, so NO_CAPABILITY's `consumed ≥ minted` only ever fires at `consumed == minted` on valid input;
- **invalid manifest** (`round_period` = 0) unchanged, and the ManifestV0 comment contradiction is confirmed resolved (defined INVALID_STATE rejection, never a crash).

### Results

- Seed corpus: **PASS 51/51** (7/7 rejections, 3/3 transitions, 4/4 distinct pairs).
- Expansion corpus: **PASS 1019/1019** (198/198 rejections, 208/208 transitions across all nine reject reasons, §10 conservation assertions all holding).
- Gate: `cargo fmt --check` and `cargo clippy --quiet --all-targets` both clean.

### Coverage caveat

The corpus exercises INVALID_STATE only via `created > consumed` (13 vectors, all with sorted worlds and valid enums). The widened guard's other branches are implemented from prose but untested by any vector: `consumed > minted`, `minted > envelope`, unassigned permit enum values, non-canonical ordering as a *transition* input, and `round_period = 0` (0 occurrences).

### Spec sufficiency

The amended prose now fully determines the guard; both prior findings are closed and **the value-sourcing exception is gone** — every constant and predicate in the implementation is justified by spec text alone (RejectReason discriminants, precondition set and order, enum assignments, supply identities, roll arithmetic, domains). No remaining ambiguity, gap, or vector disagreement.

---

# G0c Pass 3: The extant == created Clause

Widening the expansion corpus to the full totality guard exposed one more
§6 omission: the kernel also requires the blockmon count to equal
`supply.created`. The spec was amended (`87b5719`) and the expansion grew
13 `invalid-extant-mismatch` vectors; the pre-amendment implementation
failed exactly those 13, proceeding to the attempt where the kernel
rejects. The isolated session re-derived from the amended prose:

## What changed

`impl/src/kernel.rs`, `invalid_state` only: added the extant-accounting clause from the amended §6 INVALID_STATE row — valid kernel input now also requires the blockmon count to equal `supply.created` (extant == created; protocol.md §10's `extant = created − exited` with no exits in T1). Implemented as `u64::try_from(w.blockmon.len()).is_ok_and(|n| n == s.created)`, evaluated with the rest of the guard before any protocol-semantic precondition. The guard's doc comment cites the amended clause. Nothing else touched.

## Results

- Seed corpus: **PASS 51/51** (unchanged: 7/7 rejections, 3/3 transitions, 4/4 distinct pairs).
- Expansion corpus: **PASS 1136/1136** (198/198 rejections, 325/325 transitions — including the 13 new `invalid-extant-mismatch` vectors, whose only defect is the count mismatch and which now reject as INVALID_STATE instead of proceeding to the attempt). §10 conservation assertions hold on all computed transitions; the CREATED path preserves the new invariant (blockmon +1, created +1).
- Gate: `cargo fmt --check` and `cargo clippy --quiet --all-targets` (pedantic+nursery as errors) both clean.

## Spec sufficiency

The amended prose fully determined the clause: "the blockmon count equals created (extant == created, `protocol.md` §10)" maps one-to-one onto the implemented predicate with no vector-derived input; I updated the guard from the spec text before re-running the corpus. No value in the implementation is sourced from a vector; no remaining ambiguity.

Corpus coverage note (corrected outside the session): with the widened
expansion, every representable INVALID_STATE branch is vector-tested —
both remaining supply chains, unassigned enums, all three unsorted
collections, `round_period = 0`, and the extant mismatch. The only
prose-only branch left is enum discriminant zero, which is
unrepresentable on the wire by design.
