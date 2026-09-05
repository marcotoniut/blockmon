# Blockmon Canonical Encoding & Protocol Hashing (v0, provisional)

| | |
|---|---|
| **Status** | **v0.1**, provisionally pinned under `protocol.md` §1 authority; replaceable only via migration (`protocol.md` §11); every change bumps the domain version suffix |
| **Last reviewed** | 2026-09-01 |
| **Owns** | Canonical byte encoding of protocol-visible values, protocol hash and domain separation, transcript/hash-chain construction, the G0a golden-vector corpus definition |
| **Depends on** | `architecture.md` §21 (this is **protocol cryptography**, layer 1); `protocol.md` §§1-2; `battle-channel.md` §4 |

This document is the written authority an independent implementation encodes
from. If an implementation and this document disagree, the implementation is
wrong (`verification.md` §2). Scope is deliberately what G0a exercises today:
primitives, records, the battle-channel transcript objects. The authenticated
state tree is **not** defined here (Transition 1 scope; `protocol.md` §1 OPEN).

Everything here is provisional in the `protocol.md` §1 sense: pinned so bytes
are reproducible, replaceable via migration, never silently.

---

## 1. Design Rules

- Language-independent: defined in bytes, never in any language's memory layout.
- Deterministic: one semantic value, exactly one encoding. Decoders MUST reject
  every non-canonical form; "lenient reader" implementations are non-conforming.
- No self-description: no field tags, no padding, no alignment. Schema evolution
  happens by version-bumping the domain string, never by in-band tagging.
- No maps: canonical encoding v0 defines no map/dictionary type. A protocol
  value needing one must first extend this specification (sorted-by-encoded-key
  is the anticipated shape).
- Signed integers and floats: not defined in v0; no protocol-visible value uses
  them. Using one requires extending this specification first.

## 2. Primitive Encodings

| Type | Encoding | Non-canonical / invalid forms |
|---|---|---|
| `u8`, `u16`, `u32`, `u64` | fixed-width **big-endian**, 1/2/4/8 bytes | none (fixed width is always canonical) |
| `bool` | 1 byte: `0x00` false, `0x01` true | any other byte MUST be rejected |
| `bytes` | `u32` length ‖ raw bytes | length exceeding remaining input |
| `string` | `u32` length ‖ UTF-8 bytes | invalid UTF-8 MUST be rejected; no Unicode normalisation is applied (bytes compare as given) |
| `hash32` | 32 raw bytes, no length prefix | short input |
| `enum` | `u8` discriminant with spec-assigned values | any unassigned discriminant MUST be rejected |
| `optional<T>` | `0x00` absent; `0x01` ‖ encode(T) present | flag byte > `0x01` MUST be rejected |
| `seq<T>` | `u32` element count ‖ concatenated encode(T) | count exceeding remaining input |
| record | fields concatenated in specification-declared order | — |

Decoding a top-level value MUST consume the input exactly; trailing bytes MUST
be rejected. `optional` absent (`0x00`) and an empty `seq` (`0x00000000`) are
distinct values with distinct encodings, deliberately.

Length prefixes are what make concatenation unambiguous: `("A","BC")` and
`("AB","C")` encode differently. The golden vectors include this pair
explicitly because Slice B's original hand-rolled encoding collided on it.

## 3. Protocol Hash and Domain Separation

Provisional pin; any change must pass the conformance obligation (`protocol.md` §9):

- **Algorithm**: SHA-256 (FIPS 180-4). **Output width**: 32 bytes, in full.
- **Domain construction**, exact bytes:

```
ProtocolHash(domain, payload) = SHA-256( u8(len(domain)) ‖ domain ‖ payload )
```

- A **domain** is 1-255 bytes of printable ASCII (`0x21`-`0x7e`), lowercase,
  and MUST end in `/v<decimal>`. The length prefix makes (domain, payload)
  framing unambiguous: `("blockmon/aa/v0", "bb")` and `("blockmon/aa/v0b", "b")`
  hash differently even though their naive concatenations collide.
- Domains assigned in v0: `blockmon/op/v0`, `blockmon/checkpoint/v0`,
  `blockmon/state/v0`. New object kinds take new domains; semantic changes to
  an object bump its domain's version suffix.
- **Migration boundary**: the hash algorithm and this domain construction are
  ProtocolManifest fields. A future change is a `protocol.md` §11 migration.
  Objects affected by such a change: op hashes, transcript heads, checkpoint
  hashes, state commitments, and the golden-vector corpus itself (vectors are
  regenerated per manifest version and archived, never edited).

## 4. Transcript Objects (battle-channel, v0)

The objects Slice B exercises, now normative. `enum Author { A = 1, B = 2 }`;
`enum Result { A_WINS = 1, B_WINS = 2, DEFAULT = 3 }`; `0` is invalid on the
wire for both.

```
Op         := record { battle_id: hash32, seq: u64, prev_hash: hash32,
                       author: enum Author, move: string }
op_hash    := ProtocolHash("blockmon/op/v0", encode(Op))

chain      : op(seq=1).prev_hash = 0^32 (genesis); op(n).prev_hash = op_hash(n-1);
             seq strictly monotone from 1; transcript_head = op_hash(last)

Checkpoint := record { battle_id: hash32, seq: u64, transcript_head: hash32,
                       result: enum Result }
checkpoint_hash  := ProtocolHash("blockmon/checkpoint/v0", encode(Checkpoint))

StateV0    := record { transcript_head: hash32, result: enum Result }
state_commitment := ProtocolHash("blockmon/state/v0", encode(StateV0))
```

Channel signatures sign `encode(Op)` / `encode(Checkpoint)` bytes. The
signature schemes themselves are battle-channel cryptography
(`architecture.md` §21 layer 2), deliberately **not** pinned by this document:
Ed25519/X25519/HKDF in Slice B are implementation choices, and the EVM
stand-in's secp256k1/Keccak values are settlement-interface details. Only the
canonical bytes and the SHA-256 protocol hashes above are consensus-visible.

## 5. Golden-Vector Corpus (G0a seed)

Location: `conformance/vectors/g0a-vectors.json`, emitted deterministically by
`conformance/gen` (Odin) and independently re-derived from this document by
`conformance/check.py` (Python, no shared code). The corpus is small and
constitutional by design; the 10³+ fuzzed expansion is G0b, not this file.

Each `encode` vector carries the semantic value with explicit type, the
canonical bytes, and where applicable the domain and hash, so a third
implementation can verify every observable boundary of:

```
semantic value → canonical bytes → domain-separated hash → commitment/transcript
```

Required coverage (all present in the corpus): zero and maximum integers;
bool; empty/non-empty bytes and strings; multi-byte UTF-8; adjacent enum
values; absent optional vs present-empty distinction; 0/1/n-element sequences;
nested records; the `("A","BC")`/`("AB","C")` ambiguity pair; the same payload
under two domains; the domain/payload boundary-shift pair; transcript `A‖B` vs
`B‖A` ordering; the Slice B ops, transcript head, checkpoint and state
commitment; and rejection vectors (bad bool, unknown enum, invalid UTF-8,
truncated length, trailing bytes, bad optional flag).

Conformance criterion (G0a): every required target and every independent
implementation reproduces the corpus byte-for-byte, compared on emitted
artefacts, not on test exit codes.

## 6. Transition 1 Objects (provisional)

Kernel objects for the capture acceptance transition
(`prototype-and-technology.md` §1), implemented in `protocol/kernel`. All pins
here are provisional under the same authority as §§2-3. Enum zero is invalid
on the wire throughout.

```
BlockmonRecord := record { creature_id: hash32, owner: hash32, origin_permit: hash32 }
PermitRecord   := record { permit_id: hash32, subject: hash32,
                           encounter_class: enum { COMMON = 1 },
                           expiry_position: u64,          // canonical positions, exclusive
                           status: enum { RESERVED = 1, CONSUMED = 2 } }
Supply         := record { epoch: u64, envelope: u64, minted: u64,
                           consumed: u64, created: u64 }
WorldV0        := record { subjects: seq<hash32>,
                           blockmon: seq<BlockmonRecord>,
                           permits:  seq<PermitRecord>,
                           supply:   Supply }
ManifestV0     := record { round_period: u64, entropy_safety_margin: u64,
                           catch_rate_bp: u32 }            // T1 subset of the ProtocolManifest
                  // round_period MUST be ≥ 1. A manifest with round_period = 0
                  // is invalid kernel input in the same class as invalid
                  // state: a defined INVALID_STATE rejection, never a crash.
                  // Canonical execution never produces it.
CaptureCommand := record { subject: hash32, permit_id: hash32 }
ContextV0      := record { position: u64, epoch: u64,
                           entropy_round: u64, entropy_value: hash32 }
                  // kernel input (with WorldV0, CaptureCommand, ManifestV0),
                  // never wire-encoded; pinned so implementations agree on
                  // the transition signature
RejectReason   := enum { UNKNOWN_SUBJECT = 1, UNKNOWN_PERMIT = 2,
                         PERMIT_NOT_RESERVED = 3, WRONG_SUBJECT = 4,
                         PERMIT_EXPIRED = 5, NO_CAPABILITY = 6,
                         ENTROPY_MISMATCH = 7, WRONG_EPOCH = 8,
                         INVALID_STATE = 9 }
EffectsV0      := record { outcome: enum { CREATED = 1, ROLL_FAILED = 2, REJECTED = 3 },
                           reject_reason: optional<RejectReason>, // present iff REJECTED
                           roll: optional<u64>,            // present iff not REJECTED
                           creature: optional<hash32> }    // present iff CREATED
TranscriptV0   := record { command_hash: hash32, prev_root: hash32,
                           next_root: hash32, effects: EffectsV0 }
```

Canonical form: `subjects`, `blockmon` (by creature_id) and `permits` (by
permit_id) are sorted strictly ascending byte-lexicographically; anything else
is non-canonical and MUST be rejected.

Hashes and derivations, all via §3's construction:

```
world_root       = ProtocolHash("blockmon/world/v0",       encode(WorldV0))
manifest_hash    = ProtocolHash("blockmon/manifest/v0",    encode(ManifestV0))
command_hash     = ProtocolHash("blockmon/capture-cmd/v0", encode(CaptureCommand))
transcript_hash  = ProtocolHash("blockmon/transition/v0",  encode(TranscriptV0))
creature_id      = ProtocolHash("blockmon/creature-id/v0", permit_id)
capture_seed     = ProtocolHash("blockmon/capture-roll/v0",
                                entropy_value ‖ permit_id ‖ manifest_hash)
roll             = u64_be(capture_seed[0..8)) mod 10000;  success iff roll < catch_rate_bp
assigned_round(p) = p / round_period + 1 + entropy_safety_margin
reveal_position(r) = r * round_period      // strictly after p for every p, by construction
```

The `world_root` line above is the archived v0 derivation, kept because the v0 corpus is evidence of v0 semantics. New state commits through the authenticated state tree of §7, which supersedes it.

Precondition order (normative): the kernel evaluates exactly the checks below
in this order, and the first failure is the rejection reason. Every failure is
a defined rejection: it consumes nothing, returns the input state
byte-identical, and surfaces as the REJECTED outcome, never as a crash or an
implementation error (totality, `protocol.md` §2). Reasons 1-8 are protocol
semantics; INVALID_STATE (9) is the kernel's totality guard for invalid
boundary input (malformed state or manifest), which canonical execution never
produces.

```
INVALID_STATE        world is not valid kernel input: canonical form above;
                     every enum field holds an assigned value; supply
                     satisfies created ≤ consumed ≤ minted ≤ envelope and
                     the blockmon count equals created (extant == created,
                     `protocol.md` §10). Also raised for an invalid
                     manifest (round_period = 0)
WRONG_EPOCH          context.epoch ≠ supply.epoch
ENTROPY_MISMATCH     context.entropy_round ≠ assigned_round(position)
UNKNOWN_SUBJECT      command.subject ∉ subjects
UNKNOWN_PERMIT       command.permit_id ∉ permits
PERMIT_NOT_RESERVED  permit.status ≠ RESERVED
WRONG_SUBJECT        permit.subject ≠ command.subject
PERMIT_EXPIRED       position ≥ permit.expiry_position (exclusive bound)
NO_CAPABILITY        supply.consumed ≥ supply.minted
```

Provisional stand-ins, explicitly NOT frozen architecture:

- `world_root` is a **flat commitment** over the canonical state bytes. The
  authenticated state tree remains OPEN in the protocol docket; this stand-in
  proves deterministic root update, not membership. Replacing it with the real
  tree is a migration (`protocol.md` §11).
- `assigned_round`'s shape and constants, the capture seed derivation,
  `catch_rate_bp` and `creature_id`'s derivation are prototype pins of
  mechanisms `protocol.md` §5 and the ruleset own.
- Semantic rule pinned by the kernel: precondition failures are defined
  rejections that consume nothing; once the entropy-bound roll executes, the
  permit and one capture-class capability are consumed unconditionally
  (consume-on-attempt, `protocol.md` §6).

## 7. Authenticated State Tree (v1)

Provisional pin; any change must pass the conformance obligation (`protocol.md`
§9). This supersedes the flat `blockmon/world/v0` root for new state.
`blockmon/world/v0` remains defined for the archived v0 corpus, which is
historical evidence and is never regenerated.

**Domains and tags.** Each ratified state domain (`protocol.md` §1) is
authenticated by its own tree. Tags are assigned; `0` is not a valid tag.

| Tag | Domain | Record | Key |
|---|---|---|---|
| 1 | subject | `SubjectV0 := unit`, zero record-field bytes | `Subject_ID` |
| 2 | blockmon | `BlockmonRecord` | `creature_id` |
| 3 | encounter | `PermitRecord` | `permit_id` |
| 4 | supply | `Supply` | 32 zero bytes, the only admissible key |

`SubjectV0 := unit` occupies no record-field bytes, so a subject leaf's
preimage ends at its key. This is not §2's length-prefixed `bytes` primitive;
since no `bytes` field is declared, no length prefix appears anywhere in the
preimage. Treating it as a `bytes` field would prepend four zero bytes and
alter every subject leaf.

Domains assigned here: `blockmon/smt-leaf/v0`, `blockmon/smt-node/v0`,
`blockmon/smt-empty/v0`, `blockmon/world/v1`.

**Domain state.** State is a finite mapping from 32-byte key to record, not
a sequence. Every key is unique; every record is valid for its domain; where
a record carries its own identifier, that identifier equals the tree key.
The supply domain admits exactly the zero key. State violating any of these
is malformed and, under Transition 1, falls in the INVALID_STATE class of
§6. Ordering is a property of representation, not state: where an ordered
representation is required, for encoding or construction, keys appear
strictly ascending byte-lexicographically.

**Construction.** A domain tree is a sparse Merkle tree of fixed depth 256,
keyed by the record's 32-byte identifier. Leaves sit at level 0; the root is
the level-256 value, so an empty domain's root is `empty[256]`. For key `k`
and `0 <= i < 256`, `bit(i)` is bit position `i mod 8` counted from zero at
the most significant bit of byte `i / 8`. The path from root to leaf consumes
`bit(0)` first and `bit(255)` last, where `0` selects the left child and `1`
the right.

```
empty[0]   = ProtocolHash("blockmon/smt-empty/v0", "")
empty[d+1] = ProtocolHash("blockmon/smt-node/v0", empty[d] ‖ empty[d])   for d in [0, 256)

leaf(tag, key, record) = ProtocolHash("blockmon/smt-leaf/v0",
                                     u8(tag) ‖ key ‖ encode(record))
node(left, right)      = ProtocolHash("blockmon/smt-node/v0", left ‖ right)
```

Each level holds its own empty commitment. If commitments at two different
levels were equal, that would be a hash collision. Such an event falls
outside protocol-valid adversarial assumptions; it is an assumption rather
than a validation condition.

A node with one empty child is hashed like any other node; there is no path
collapse. The level-0 slot of an absent key holds `empty[0]`.

**World commitment.**

```
WorldCommitmentV1 := record { subject_root:   hash32, blockmon_root: hash32,
                              encounter_root: hash32, supply_root:   hash32 }

world_root = ProtocolHash("blockmon/world/v1", encode(WorldCommitmentV1))
```

The field set and its order are constitutional: admitting a further ratified
domain is a `protocol.md` §11 migration, never a ProtocolManifest field. The
settled artefact's `supply_commitment` is this same root, so
`supply_commitment == supply_root` holds for every valid settled artefact.

```
SUBJECT   -> WorldCommitmentV1.subject_root
BLOCKMON  -> WorldCommitmentV1.blockmon_root
ENCOUNTER -> WorldCommitmentV1.encounter_root
SUPPLY    -> WorldCommitmentV1.supply_root
```

A domain root occupies one named field; position is what verification checks.
The mapping uses the field name, not the tag's numeric value, so it survives
future non-contiguous discriminants. A populated domain binds semantics via
the tag in every leaf. An empty domain root has no leaves, so field position
is the only binding; that is why it is constitutional.

Tree construction and world commitment schema versions operate on independent
axes. `WorldCommitmentV1` commits domain roots built by construction v0,
specifically the `smt-leaf`, `smt-node` and `smt-empty` domains mentioned
above. This association is stated explicitly because later world schemas may
retain construction v0, and later constructions may appear under an unchanged
world schema, rather than relying on matching suffixes.

**Proofs.**

A logical proof consists of `(tag, key, record or absence, 256 sibling
commitments ordered leaf to root)`. It contains no leaf hash or path data. The
verifier computes the leaf itself, using the key to determine the path.
Verification then recomputes the domain root from the leaf and siblings,
compares it against the claimed domain root, and checks that root at its
assigned position in `WorldCommitmentV1`.

A proof is malformed when its encoding or domain-local record semantics are
invalid: an incorrect sibling count, an inadmissible domain key, an invalid
record encoding, or, where the record carries an identifier, one that does
not equal the proof key. Malformedness is not just byte shape. The binding is
checked at the proof boundary, not left to every producer having built valid
state, because under the domain state rule above that record is not
admissible at that key at all.

**Authenticated update.**

An update is `(tag, key, old value, new value, 256 sibling commitments ordered
leaf to root, claimed pre-state domain root)`, where each value is a record or
an absence. The verifier computes the old level-0 value, climbs the siblings,
and requires the result to equal the claimed pre-state domain root. It then
computes the new level-0 value, climbs the same siblings, and that result is the
post-state domain root.

```
root_from(key, level_zero, siblings) is the root recomputation of Proofs above,
using the key to select the path.

old_level_zero = leaf(tag, key, old_record)  if the old value is a record
                 empty[0]                    if the old value is an absence
new_level_zero = leaf(tag, key, new_record)  if the new value is a record
                 empty[0]                    if the new value is an absence

required:  root_from(key, old_level_zero, siblings) = claimed_pre_root
then:      post_root = root_from(key, new_level_zero, siblings)
```

One sibling sequence serves both climbs. Every sibling on a key's path commits a
subtree excluding the key, so only the level-0 slot moves. This holds for
modifications, insertions, and deletions. No path collapse redistributes
siblings.

The post-state root an update produces must equal the domain root of a full
derivation over the post-state mapping. Updates anchor in the pre-state and are
not root constructors. An old value not committed by the claimed pre-state root
is refused, not climbed. No update can assert a root its pre-state does not
support. A rejected update leaves the domain root at its pre-state value.

An update's rejection classes are those of a proof, applied to both of its
values.

Rejection has two classes, and they are distinct outcomes:

| Class | Cases |
|---|---|
| Malformed | sibling count ≠ 256; key length ≠ 32; unassigned `tag`; a supply key other than 32 zero bytes; record bytes that fail strict exact-consume decoding (§2); a record identifier that does not equal the proof key, where the record carries one |
| Well-formed but invalid | recomputed root ≠ claimed domain root; the claimed domain root does not appear at its assigned position in `WorldCommitmentV1`; an update's old value does not climb to the claimed pre-state domain root |

**Cost.** Committing one key costs one leaf hash and 256 node hashes,
independent of domain size. A state-changing transition costs that per key
touched, plus one `blockmon/world/v1` recomputation after its
authenticated-key updates. A rejected transition returns the input commitment
unchanged and incurs no state-recomputation hash. `protocol.md` §2 bounds the
number of keys a transition may touch. Verification cost is accounted
separately: a verifier holding no state climbs one proof per authenticated
read, which is not part of a transition's execution cost.
An update that checks its anchor climbs twice, costing a verifier without
domain state two leaf hashes and 512 node hashes per key. A producer with the
domain state already knows the pre-state root and climbs once. Both costs are
independent of domain size, as bounded by `protocol.md` §2.

**Proof encoding.** The compact wire format is deliberately unpinned. Any
encoding, for example a presence bitmap with the non-empty siblings, MUST
decode to the exact logical proof above and thus to the same root. This does
not conflict with the one-encoding rule in §1, which applies to consensus
objects. A compact proof is a transport representation, never itself hashed
or committed. Should a proof become consensus-visible, its encoding must be
pinned before that happens.
