Verbatim report of the isolated implementing session, 2026-10-18.

The implementer reviewed `docs/architecture/canonical-encoding.md`, `docs/architecture/protocol.md`, `conformance/vectors/g0a-t1-v1.json` and `conformance/vectors/g0a-t1-v1-expansion.json` as they stood before any cleanroom amendment. It also saw a crate skeleton holding only lint configuration, the toolchain pin and the lockfile.

It saw nothing else. Not `protocol/`, `conformance/gen*`, `conformance/fuzz/`, `check.py`, the earlier cleanrooms, or the audit that commissioned this pass.

`just g0c-v1` reproduces the latest run, and each report quotes what its scripts found. The run logs and analysis scripts the sessions name are not kept.

---

# G0c cleanroom report: Transition 1 under `blockmon/world/v1`

## RESULT

**FAIL**, on one well-argued divergence. No invariant was violated and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Informational values (outside the spec) | Disagreeing |
|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 18 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 272 | 6801 | 88 | 1 | 0 |

All 88 mismatches fall in the eight `t1v1-Invalid_State_Bad_Enum-*` cases, 11 fields each. In those cases the corpus records `null` for `input_commitment`, `output_commitment` and `transcript_hash`, where my implementation computes defined values (see Divergences). Every other recorded value in both corpora is reproduced from its inputs. That covers all three hand-derived checks byte for byte, including `world_commitment_bytes`, and all 264 remaining expansion cases.

Invariant assertions ran on all 275 computed transitions with 0 violations. The checks cover protocol.md §10 conservation, §6 consume-on-attempt and no reuse, canonical-encoding.md §6 rejection semantics, and the §7 proof, update and full-derivation agreement.

Quality gate, run in `impl/`:
- `cargo fmt --check`: pass
- `cargo clippy --quiet --all-targets --all-features` (pedantic, nursery, cargo, warnings denied): pass
- `cargo test --release --quiet`: 43 passed, 0 failed

Run with `cargo run --release` (default paths) or `cargo run --release -- ../vectors/g0a-t1-v1.json ../vectors/g0a-t1-v1-expansion.json`; it exits nonzero. Full output is in `final-run.txt`. The first full run is preserved in `first-run.txt`.

## Files read

Under STAGING (`/private/tmp/claude-501/-Users-marcotoniut-repos-games-blockmon/c68e5a5b-0b9e-4a74-bb57-f907fb710f69/scratchpad/g0c-v1`):

- `spec/canonical-encoding.md`, in full
- `spec/protocol.md`, in full
- `vectors/g0a-t1-v1.json`, in full, including its recorded outputs, while learning the format before implementing
- `vectors/g0a-t1-v1-expansion.json`. Before implementing, I read its top-level metadata (including the `coverage` tally), case `t1v1-attempt-000` in full with its outputs, and the input fields of all cases through scans for types, ranges, ordering and enum values. After the first run, I read the recorded values of the eight mismatching cases to describe the divergence.
- `impl/Cargo.toml`, `impl/rust-toolchain.toml`, `impl/rustfmt.toml`, `impl/.gitignore`, `impl/Cargo.lock`, `impl/src/main.rs` (the stub)
- Files I wrote: `impl/src/{main,encoding,t1,smt,world,kernel,invariants,corpus}.rs`, `coverage_scan.py`, `first-run.txt`, `final-run.txt`, this report

Nothing outside STAGING was opened. Cargo built against the installed 1.96.0 toolchain and the local crate cache for the three declared dependencies; I opened none of those files. `coverage_scan.py` was first written one directory above STAGING by a path slip and then moved in. One stray `git -C .. status` from `impl/` answered "not a git repository" and read nothing.

## Ambiguity register

Each entry gives the location, the open question, the reading I implemented, and whether the corpus settled it.

1. **Commitment of a world holding an undecodable record.**
   - *Location*: canonical-encoding.md §7 "Domain state" and `leaf`, §2 `enum` row, §6 "Enum zero is invalid on the wire throughout".
   - *Question*: what is the v1 commitment, and therefore the transcript, of kernel input holding a permit whose `status` is 0?
   - *Reading*: each domain tree commits the mapping it holds, with record bytes taken from the mechanical §2 encoding (status 0 encodes as `0x00`). The commitment and the transcript are both defined.
   - *Corpus*: not consulted. It disagrees; see Divergences.
2. **Unsorted lists.**
   - *Location*: §6 "Canonical form" against §7 "Ordering is a property of representation, not state".
   - *Question*: is an unsorted but unique list a different state, and what does it commit to?
   - *Reading*: the kernel rejects it with INVALID_STATE, because §6 lists canonical form as a precondition. The commitment is computed over the mapping, so it does not depend on listing order.
   - *Corpus*: not consulted. It agrees in all 16 unsorted cases.
3. **Repeated keys.**
   - *Location*: protocol.md §1, "Without uniqueness, the value at a key is undefined".
   - *Reading*: the commitment is undefined. The checker would print an undefined marker and fail.
   - *Corpus*: not exercised.
4. **Transcript roots under world/v1.**
   - *Location*: §6 `TranscriptV0`, §6 note that the `world_root` line is archived, and §3 "semantic changes to an object bump its domain's version suffix".
   - *Question*: what do `prev_root` and `next_root` hold, and under which domain is the transcript hashed? The prose never says these fields are world roots at all.
   - *Reading*: `ProtocolHash("blockmon/transition/v0", ...)` over the v1 `world_root` of the input and output. For a rejection, both are the input root.
   - *Corpus*: not consulted. It agrees in 264 cases.
   - *Note*: the meaning of two fields changed while the domain suffix stayed `v0`, which §3 says should not happen.
5. **What a creation writes.**
   - *Location*: §6.
   - *Question*: the owner of the created `BlockmonRecord` is not stated. Neither is the `supply.created` increment as an effect; it is implied only by the INVALID_STATE rule `extant == created` and §10.
   - *Reading*: `owner = command.subject`, which equals `permit.subject` once WRONG_SUBJECT has passed. `created += 1` on CREATED only.
   - *Corpus*: not consulted. It agrees.
6. **Which root is `supply_commitment`.**
   - *Location*: §7, "The settled artefact's `supply_commitment` is this same root, so `supply_commitment == supply_root`".
   - *Question*: "this same root" follows the `world_root` definition, so it can be read as `world_root`, which contradicts the clause after it.
   - *Reading*: `supply_root`, per the explicit equality.
   - *Corpus*: not needed to decide, but I had already seen the hand tier record `supply_commitment` equal to `supply_root` before implementing, so I declare the exposure.
7. **Overflow in `assigned_round`.**
   - *Location*: §6, with protocol.md §2 "defined overflow behaviour".
   - *Question*: `p / round_period + 1 + entropy_safety_margin` can exceed `u64`.
   - *Reading*: exact integer arithmetic. An out-of-range round equals no `u64` `entropy_round`, so the result is ENTROPY_MISMATCH.
   - *Corpus*: not exercised.
8. **`catch_rate_bp` above 10000.**
   - *Location*: §6. Only `round_period = 0` is declared an invalid manifest.
   - *Reading*: the manifest is valid, and `roll < catch_rate_bp` always succeeds.
   - *Corpus*: not consulted. It is exercised by 37 executed cases and agrees.
9. **Creature key already present.**
   - *Location*: §6. The precondition list is exhaustive, and creation writes `creature_id(permit_id)`.
   - *Question*: what happens if the blockmon domain already holds that key? A RESERVED permit whose creature already exists passes every §6 validity rule. No precondition covers it, and an insertion would break `extant == created`.
   - *Reading*: the record is written at its key, and the invariant checker reports the resulting count violation.
   - *Corpus*: not exercised.
10. **Validity of a `BlockmonRecord`.**
    - *Location*: §7, "every record is valid for its domain".
    - *Question*: no validity rule is stated for `BlockmonRecord`. Candidates would be an admitted owner, or `creature_id == creature_id(origin_permit)`.
    - *Reading*: none beyond encoding and identifier binding. INVALID_STATE checks exactly the §6 list.
    - *Corpus*: not exercised; every owner in the corpora is an admitted subject.
11. **§3's own example breaks §3's domain rule.**
    - *Location*: §3. The boundary-shift example `("blockmon/aa/v0b", "b")` uses a domain that does not end in `/v<decimal>`.
    - *Reading*: the rule is enforced on every domain I hash. The example is tested only for its framing property, below the domain check.
    - *Corpus*: not relevant.
12. **Recorded fields the specification does not define.** These are compared only informationally, under the stated readings, and never decide PASS or FAIL. All agree.
    - `rejected`: read as `effects.outcome == REJECTED`.
    - `roots_unchanged`: read as the set of `{subject_root, blockmon_root, encounter_root, supply_root, world_root}` equal between input and output. The recorded alphabetical order is not compared.
    - `reads`: read as the keys consulted by the precondition checks that ran (supply for WRONG_EPOCH, then the commanded subject, then the commanded permit), compared as a set. protocol.md §2 speaks of reading authenticated keys, but no text says which keys Transition 1 reads, whether a rejection reads keys beyond its failing check, or whether proving the new creature key absent counts as a read. The record does not count it as one.
    - `writes`: read as the keys whose committed value changes, compared as a set. The recorded `reads` are in tag order, while the recorded `writes` are not (encounter, supply, blockmon). Neither order is defined.
    - `keys_read`, `keys_written`: the cardinalities of the two sets above.
    - `bound` (`max_keys_read` and `max_keys_written`, both 3): protocol.md §2 makes the bound a manifest constant but pins no value (OPEN, Q19). Not compared; my computed sets never exceed 3.
    - Expansion `coverage`: compared against my own outcome tally, and agrees. `seed`, `provenance`, `records`, `tier`, `derivation` and `scenario_source` are prose or generator metadata and are not compared.
    - The hand tier's top-level `outcome` duplicates `effects.outcome` and is compared as such.

## Divergences

**Cases**: `t1v1-Invalid_State_Bad_Enum-00` to `-07`. In each one, a permit in the input world has `status: 0` and is the commanded permit. Both implementations agree on the outcome (REJECTED, `reject_reason` 9), the effects and the byte-identical output state.

**Fields**: per case, all 11 of these mismatch, 88 in total:
- `input_commitment.{subject_root, blockmon_root, encounter_root, supply_root, world_root}`
- `output_commitment` with the same five members
- `transcript_hash`

The recorded value is `null` in every one; the corpus stores both whole commitment objects and `transcript_hash` as `null`. Because the transition is a rejection, my computed output commitment equals the input commitment, so each root value below applies to both the `input_commitment` and the `output_commitment` field.

| Case | Field | Computed |
|---|---|---|
| Bad_Enum-00 | subject_root | `0x1dbce96b1b193a6e95f6c99c95e12f38660b3e7d1aa3c851289963ce9295f7ca` |
| | blockmon_root | `0x1123125e19ba215457e770939a1593dbf7d17b5f9f62bc81d9cd8f529b5689ed` |
| | encounter_root | `0x87442f18d8a24ff9844543226945031120367ef821637c02255467607c59d798` |
| | supply_root | `0x4705bce250685424210ce2e124ac937587fa816f944f01a084b1ecb08ae07522` |
| | world_root | `0xc263c0b6d6e657d75953fb7ed2b71ad671ca7b2612026e1b8a4d011f15280eb0` |
| | transcript_hash | `0x2bbbde551b505971891f712524eb546522c36035d503510ba3fd51b318c4e7f6` |
| Bad_Enum-01 | subject_root | `0x78a79002c3cc0a0d44443fee47adb7eedb48df97f41abbd72a2c84083ef9d4ee` |
| | blockmon_root | `0xd8816ddc24a659c0fbdb7e85cd06fa9d91e03561444458f7c626d14775bbd0a0` |
| | encounter_root | `0x1350fcd8c28b0741caaaabd33c001c519b6d2bc1b4516425c3fe74a9164a4c17` |
| | supply_root | `0x0147fcc236a529afa731f48e8e948ca512691e19eb260f3045e5978c46bfc0a6` |
| | world_root | `0x15cd2c4ca54840ad4ca495548e29892342d4c6538debc55a714f57374ee74e84` |
| | transcript_hash | `0xe286d5c6df5e4ae917d17e3478f68badb934fbf93a3d3fd2e0c3c07e5e833084` |
| Bad_Enum-02 | subject_root | `0x2e44d5a4249885d73ac5de0df053d7fcc265b0de2d10761badab18c53b44f6b4` |
| | blockmon_root | `0xaff249e48334219edbfa66e5559b683d01b09419eb367376efdb3ec1942cf3b3` |
| | encounter_root | `0xbdd9b07d1864953c5afb4361507fed51302594ae7abcb5829f6b4d5cc91aec22` |
| | supply_root | `0xc4cf711658306d080928f7728536e9ec722c100bca2f9d3cc14188d25bf35df3` |
| | world_root | `0x7458e250096bb42774c97883c95b11d7b236146ffcfebcff8f1a8bd5d95b6b2f` |
| | transcript_hash | `0xe7d3d64f4a4010d4e7d2092a2710526322dca5da50672b338976d3802a8215db` |
| Bad_Enum-03 | subject_root | `0xc28542334ae0b08df7b4445ee984499842930706fc5302eb4f13845f42c5173d` |
| | blockmon_root | `0x5acce239f4c8b09eec31e2d6eb45a8ca706d1c9fdb07d5965a39484bcd842b52` |
| | encounter_root | `0x91bc23a1231ac29fdcf60057b54f032e6f777d97fc503e7ebdfdbbcc040df8da` |
| | supply_root | `0x37d4ea1894ed8a7270552cd3aa219d4ce83c27a67ae52f754fe2cc9addacb85a` |
| | world_root | `0x5017b699afc042baf58aaedf1e80ab6678017bbc048aee222caef8ba5cadc0f2` |
| | transcript_hash | `0x6503d7bf4d3d29fbab00efb6e9910ea5113001416aa53c46b8aa2133a1aff366` |
| Bad_Enum-04 | subject_root | `0xfb252289de1fa3ae9f0b58d88c494855fa96f26221d82a9dfc8074fcc2d84ca2` |
| | blockmon_root | `0xd821e1fa3feb9b2732426393cfff4692b3d76f85f2662a46208b478fe648e8eb` |
| | encounter_root | `0x48bc708bb4f621c17d442f69c6741575fe67ce64d40c2f8c86c7b0fd33a857aa` |
| | supply_root | `0x736895f262c705d73c02cbabc0e7cda4e8d94f115c1c7ad4eb3609210f7d93e7` |
| | world_root | `0x6754549cd357b602922170eaa5b890292ca893fbfbf9d104317eced47056272a` |
| | transcript_hash | `0x0b8875bbf7ec5b55768d489cf6821278536a8f80dd354e1deb544eb17d44f8b4` |
| Bad_Enum-05 | subject_root | `0xda77e28e537fca07d3e78ed423416d40c17258e504570e8f0f09379336db0278` |
| | blockmon_root | `0xd8816ddc24a659c0fbdb7e85cd06fa9d91e03561444458f7c626d14775bbd0a0` |
| | encounter_root | `0x183a229a9b893b1a77e23888bdcde1666edd6d96ffd24970928aaa057bc91385` |
| | supply_root | `0xfaf8a1df2ad40f9c7a3fe4d714f4ac42888578c94208cca00556874ab9241eac` |
| | world_root | `0xe62cfadcf383e4134e429d2f37917a28b41e5c7fa83084e88eef1f21820c544b` |
| | transcript_hash | `0x6d7a9d3149e60494e4c10b5d939bab9cab8c5636a07fc0bc6a2caa688d5a83fa` |
| Bad_Enum-06 | subject_root | `0x333d3847998784b544bc092d0632216f263d6b06a39a1b92b468c90d00227ff9` |
| | blockmon_root | `0x383e3c04be5d711e690c901d60a1230c648a7daec1cec1f0d4ef9bd901e5229a` |
| | encounter_root | `0x105c545872de9bbc3758340c7556ff6a205c52345596550d42115054060fccb9` |
| | supply_root | `0x2429bbf37e193a31d07804635257a86a6db8f03f718b93d7ff38b3ec638fdd37` |
| | world_root | `0x0d809bea57e07f9d8dc1aae2bbf46bf42969337df75159894b764e32c4bdfa3d` |
| | transcript_hash | `0x08296100d4a6d32aac868f405107b51125c171c4d3d08da23d96469dc5303fd9` |
| Bad_Enum-07 | subject_root | `0xafbfd6a06e356336db319633209dabb329d461047d9bb2e0abdc67bf7d950a24` |
| | blockmon_root | `0xf42cd012028908ecc32874e72d347f94d6d003f2778c30bce6486082f8547468` |
| | encounter_root | `0x00bf7789e542b98950af054a6ca98bab0c51eed6d051193f30a61f9719ec6b16` |
| | supply_root | `0xc340135846971428cda6305abf456d58f7cd0221c115e746fe7800b3f190bf72` |
| | world_root | `0xf238fedc89e2afa58cc46a8b03977efe64648e8eb08d2fa01266bfab70ef27fc` |
| | transcript_hash | `0xf4d85c3d3d9bf166953a437bb187cbd94cd1e34ec36cd2035e90d893b5fc4eda` |

The two blockmon roots ending `...bd0a0` are `empty[256]`, the empty-domain root that the hand tier also records.

**Spec text supporting the computed values:**

- protocol.md §2: `transition(prev_state, commands, entropy, protocol_manifest) -> { next_state, transcript }`, under a totality requirement. Every transition has a transcript, and `TranscriptV0`'s `prev_root` and `next_root` are plain `hash32`, not `optional`.
- canonical-encoding.md §6: "Every failure is a defined rejection: it consumes nothing, returns the input state byte-identical, and surfaces as the REJECTED outcome". INVALID_STATE is "the kernel's totality guard for invalid boundary input", a defined rejection like the others.
- §7, Cost: "A rejected transition returns the input commitment unchanged and incurs no state-recomputation hash." This presupposes that a rejected transition has an input commitment.
- §6, INVALID_STATE: "every enum field holds an assigned value". The check presupposes that kernel input can carry an unassigned discriminant. §2 encodes an enum as its `u8` discriminant, so `encode(record)` and the leaf are mechanically defined.
- §7, Domain state: "State violating any of these is malformed and, under Transition 1, falls in the INVALID_STATE class of §6." The stated consequence of malformed state is the rejection class, not a missing commitment. The reference itself commits other malformed state: supply ordering, `extant != created` and unsorted lists all carry recorded roots, and §7 draws no distinction between those and an unassigned discriminant.
- §7 builds each domain tree independently. Even if the encounter leaf were undefined, nothing in the prose withholds `subject_root`, `blockmon_root` or `supply_root`, which the corpus also records as `null`.

**Text a defender of the record would cite:** §6 "Enum zero is invalid on the wire throughout", §1 "one semantic value, exactly one encoding", and §7's proof table, under which such record bytes are malformed, so no valid proof could ever open that leaf. That reading is defensible. The specification never states it, though, never declares a commitment or transcript nullable, and would then still have to say what transcript a totality-guard rejection produces.

**Suggested resolution**: the specification should choose one of two rules.
- Commitments are defined over the §2 encoding for every representable kernel input.
- Worlds holding an undecodable record have no commitment. In that case the specification must also say what transcript such a rejection emits, and whether the well-defined domain roots are withheld too.

## Changes after first run

The first full run (`first-run.txt`) and the final run (`final-run.txt`) report the same 88 mismatches: the (case, field, computed) triples are identical, checked by diff. No kernel, encoding, tree or commitment code changed after the first run.

1. **Reporting only.**
   - *Prompted by*: the first run printed `recorded=<absent>` for the 80 commitment fields, because the parent object is `null`.
   - *Change*: I added `corpus::member`, which reports a recorded `null` parent as `null` for its fields.
   - *Spec justification*: none needed, since this changes no computed value.
2. **Two unit tests added**, with no behaviour change:
   - `t1::tests::transcript_is_three_hashes_then_effects` checks the §6 `TranscriptV0` layout and domain.
   - `world::tests::invalid_but_encodable_state_still_commits` makes ambiguity register entry 1 visible in the test suite.
3. **`coverage_scan.py`**: I moved it into STAGING and changed it to print the set of failing checks per case. This is analysis only.

Before the first run, three unit tests failed and were corrected. Two were errors in the tests themselves: a fixture whose "wrong" entropy round was the correct one, and a threshold test that ignored the manifest hash's part in the seed. The third exposed ambiguity register entry 11.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula in the kernel, encoding and tree code comes from the two spec documents:

- Hashing and domains:
  - Domain framing and SHA-256: §3.
  - `manifest/v0`, `capture-cmd/v0`, `transition/v0`, `creature-id/v0` and `capture-roll/v0`: §6.
  - `smt-leaf/v0`, `smt-node/v0`, `smt-empty/v0` and `world/v1`: §7.
- Discriminants:
  - Outcome, RejectReason, `encounter_class` and `status`: §6.
  - Tags 1 to 4: §7.
- Record field orders, `WorldCommitmentV1` field order and the zero supply key: §6 and §7.
- Tree construction: depth 256, bit numbering, path direction, sibling order (leaf to root), the empty ladder and no path collapse: §7.
- Roll: modulus 10000, first 8 bytes big-endian, and the strict `<`: §6.
- `assigned_round`, the precondition order, the INVALID_STATE predicate and consume-on-attempt: §6.

The exceptions concern the corpus format, not protocol semantics, and were taken from the corpus files:
- the JSON representation: `0x`-prefixed lowercase hex, decimal strings for `u64` and `u32`, integers for enums, `null` for an absent optional, and field names such as `input_commitment`;
- the `tag:0x<key>` label format and root-field names used in the informational `reads`, `writes` and `roots_unchanged` comparisons;
- the shape of the `coverage` object.

## Coverage observations

The following spec branches and rules are not exercised, judged from the inputs alone. `coverage_scan.py` reproduces the scan.

- **Precondition precedence is mostly unpinned.** Only three pairings occur in cases that fail more than one check: INVALID_STATE with NO_CAPABILITY (8), INVALID_STATE with PERMIT_NOT_RESERVED (8), and UNKNOWN_SUBJECT with WRONG_SUBJECT (8). A kernel that swapped WRONG_EPOCH and ENTROPY_MISMATCH, PERMIT_NOT_RESERVED and WRONG_SUBJECT, or PERMIT_EXPIRED and NO_CAPABILITY would reproduce both corpora. My unit test `precondition_order_first_failure_wins` covers every adjacent pair of checks that can fail together.
- **The roll threshold's strictness is unpinned.** No executed case has `roll == catch_rate_bp`, so `<` and `<=` are indistinguishable.
- **INVALID_STATE subclasses not exercised:**
  - an unassigned `encounter_class`;
  - `status` discriminants other than 0 (3 to 255);
  - repeated keys in any domain;
  - a blockmon record failing any domain rule beyond count and order.
- **Arithmetic edges not exercised**: `assigned_round` overflow. The maximum margin is 8 and the maximum `round_period` is 4096.
- **Kernel edges not exercised**: a creation whose creature key already exists.
- **Domain shapes not exercised**: an empty subject domain and an empty permit domain. An empty blockmon domain occurs in 75 cases.
- **Tree depth is barely exercised.** The longest shared prefix between adjacent keys in one domain is 11 bits, because every key is a random hash. A tree that mishandles keys sharing more leading bits would pass.
- **Proofs and authenticated updates are not exercised.** Nothing is recorded for them or for their malformed and invalid rejection classes. They are covered by my unit tests. On every transition from valid input, my checker also verifies proofs for the keys read, and on every executed transition it checks each authenticated update's climb against the full derivation.
- **Only single transitions.** There are no sequences, retries or replays. My invariant checker replays each executed command on its own output and asserts a rejection.
- **The hand tier is narrow.** It holds only valid input states, so whether a rejection "reads" keys beyond its failing check is never tested. `world_commitment_bytes` appears only in its three checks.
- **What is exercised, for balance** (counts are executed cases):
  - `catch_rate_bp` of 0 (15) and of 10000 or more (37);
  - `round_period` of 1 (27) and margin 0 (37);
  - the last capability (34);
  - both entropy-mismatch directions;
  - `round_period = 0`;
  - expiry at the bound (pinning the exclusive bound);
  - unsorted lists in each domain;
  - each supply-ordering violation.

---

Verbatim report of the second isolated session, 2026-10-18. It saw the amended `canonical-encoding.md` and `protocol.md`, both Transition 1 v1 tiers as amended after the first pass, 278 expansion cases, plus its own first-pass crate and report. Nothing else. The harness stopped it writing this file, so the text is copied unchanged from its final message.

# G0c cleanroom report, pass 2: Transition 1 under `blockmon/world/v1`

## RESULT

**PASS**. Every recorded value in both corpora is reproduced, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational values (outside the spec) | Disagreeing |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 18 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 278 | 6951 | 0 | 0 | 1 | 0 |

The first pass's only divergence is closed. Its 88 mismatches were all in the eight `t1v1-Invalid_State_Bad_Enum-*` cases. The regenerated corpus now records, in each of those 88 fields, exactly the value the first pass computed. I checked that by script after the first run, against the table in `REPORT-pass1.md`.

Invariants were asserted on all 281 computed transitions: 132 executed and 149 rejected. No assertion failed.

Quality gate, run in `impl/`:
- `cargo fmt --check`: pass
- `cargo clippy --quiet --all-targets --all-features` (pedantic, nursery, cargo, warnings denied): pass
- `cargo test --release --quiet`: 50 passed, 0 failed

The first run of the updated checker passed. Its output is saved in `g0c-v1/first-run-pass2.txt`. The final run, `g0c-v1/final-run-pass2.txt`, is byte-identical to it.

## Files read

All paths are under STAGING (`/private/tmp/claude-501/-Users-marcotoniut-repos-games-blockmon/c68e5a5b-0b9e-4a74-bb57-f907fb710f69/scratchpad/g0c-v1-pass2`).

- `spec/canonical-encoding.md`, in full.
- `spec/protocol.md`, in full.
- `g0c-v1/REPORT-pass1.md`, in full.
- `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml` and `.gitignore`, plus all eight files in `src/`, in full. `Cargo.lock` was listed but not opened.
- `vectors/g0a-t1-v1.json`:
  - Before implementing, I read the top-level metadata (`tier`, `commitment_version`, `derivation`, `scenario_source`, `bound`), the check names and the union of check field names.
  - After the first run, `coverage_scan.py` read the inputs.
  - I did not view any recorded output value of this file. Those were compared only inside the checker.
- `vectors/g0a-t1-v1-expansion.json`:
  - Before implementing, I read the top-level metadata (`tier`, `commitment_version`, `provenance`, `records`, `seed`, `coverage`), the union of case field names, the case-name families, and a truncated print of the four input objects of `t1v1-attempt-000`.
  - After the first run, I scanned the inputs of every case with `coverage_scan.py` and inspected the inputs of the six `Creature_Exists` cases.
  - Also after the first run, a script compared the recorded commitments and transcript hashes of the eight `Bad_Enum` cases against the first report's table. It printed only the agreement count.

Files I wrote:
- edits to `impl/src/{t1,kernel,world,smt,invariants,corpus,main}.rs`;
- `g0c-v1/coverage_scan.py`, new because the first pass's script is not in STAGING;
- `g0c-v1/coverage-scan-pass2.txt`, `g0c-v1/first-run-pass2.txt`, `g0c-v1/final-run-pass2.txt`.

The harness blocked `REPORT-pass2.md`, so this report exists only as this text.

Nothing outside STAGING was opened. My first command changed into STAGING. Cargo built with the installed 1.96.0 toolchain and the local crate cache for the three declared dependencies, and I opened none of those files.

## Changes from the first pass

### Made before the first run of the updated checker

1. **CREATURE_EXISTS discriminant** (`t1.rs`).
   - *Change*: added `RejectReason::CreatureExists = 10`.
   - *Text*: §6, `RejectReason := enum { ..., INVALID_STATE = 9, CREATURE_EXISTS = 10 }`.
2. **CREATURE_EXISTS precondition** (`kernel.rs`).
   - *Change*:
     - The check is evaluated last, after NO_CAPABILITY and before the roll.
     - A hit is a defined rejection: the input state comes back byte-identical, no roll is made and nothing is consumed.
     - The blockmon key `creature_id(permit_id)` joins the kernel's read list when this check runs.
     - The first pass's branch that overwrote an existing record at the creature key is removed, because nothing can reach it any more.
   - *Text*:
     - §6, the precondition list, which now ends with `CREATURE_EXISTS creature_id(command.permit_id) is already a blockmon key`.
     - §6, "the kernel evaluates exactly the checks below in this order, and the first failure is the rejection reason. Every failure is a defined rejection: it consumes nothing, returns the input state byte-identical".
     - §6, "once the entropy-bound roll executes, the permit and one capture-class capability are consumed unconditionally".
3. **The commitment moves by authenticated updates** (`kernel.rs`, `world.rs`, `smt.rs`, `corpus.rs`).
   - *Change*:
     - The kernel now declares its writes: the commanded permit, the supply record and, on CREATED, the new blockmon key with an absent old value.
     - The reported output commitment is the input commitment moved through §7 updates of those keys. Each update is anchored in its domain's current root.
     - Full derivation over the output world is now only an invariant.
     - Each corpus case arrives as a complete input world, so each case is its own genesis. Siblings come from the input domain's leaf set, which stands in for a store built at genesis.
     - No value changes wherever the invariant holds.
   - *Text*:
     - protocol.md §2: "The Transition 1 kernel moves `world/v1` via that mechanism. Siblings for each touched key come from the store, not a walk over the world; only genesis builds the store from the full world." Also "Roots and proofs are gated against the state walk".
     - canonical-encoding.md §7: "The post-state root an update produces must equal the domain root of a full derivation over the post-state mapping".
     - §7 Cost: "A state-changing transition costs that per key touched, plus one `blockmon/world/v1` recomputation after its authenticated-key updates".
4. **New invariants** (`invariants.rs`).
   - *Change*: the checker now also asserts the following.
     - The declared writes are exactly the keys whose value changed, with their true old and new values.
     - The commitment moved by updates equals full derivation.
     - CREATURE_EXISTS is returned only when `creature_id(permit_id)` is present.
     - No transition executes when that key was present.
     - A rejection declares no writes.
   - *Text*: the same as items 2 and 3.
5. **Reporting** (`corpus.rs`, `main.rs`).
   - *Change*: the reason tally has a slot for discriminant 10. Each corpus also prints its largest computed read and write sets, which are not compared.
   - *Text*: §6 for the discriminant. The sets need none, because they decide nothing.
6. **Function split, no behaviour change.**
   - *Change*: the kernel is split into `transition` (the preconditions) and `execute` (the roll and consumption), to meet clippy's length limit.
7. **Unit tests.**
   - *Change*: six new tests, taking the count from 43 to 49:
     - `existing_creature_key_rejects_before_the_roll`
     - `writes_name_exactly_the_touched_keys`
     - `advancing_by_the_kernel_writes_matches_full_derivation`
     - `creature_exists_rejection_reports_nothing`
     - `an_overwriting_creation_is_caught`
     - `a_misdeclared_write_is_caught`

**Exposure declared.** Before implementing I saw two corpus values. One was the expansion's `coverage` tally, with six rejections under reason 10. The other was the hand tier's `bound.max_keys_read` of 4; the first pass saw 3. Neither decided anything. The discriminant and its position come from §6. The read set of 4 follows from the first pass's reading of `reads` once §6 adds a check that consults the blockmon key.

### Made after the first run of the updated checker

8. **Repeated identical entries now commit** (`world.rs`).
   - *Change*: a key listed twice with identical records commits the mapping it denotes. Two different records at one key still have no commitment.
   - *What prompted it*: no mismatch did. The first run had no mismatches, and the corpora hold no repeated key. I made the change on re-reading the new §7 paragraph while assessing register entry 3. The final run output is byte-identical to the first.
   - *Text*:
     - §7, "A rejected transition therefore always has an input commitment to return".
     - §7, "State is a finite mapping from 32-byte key to record, not a sequence".
     - protocol.md §1, "Without uniqueness, the value at a key is undefined". This still governs conflicting records.
   - *Tests*: `repeated_key_is_not_a_mapping` was replaced by `a_repeated_identical_entry_commits_its_mapping` and `conflicting_records_at_one_key_are_not_a_mapping`, giving 50 tests.
9. **Doc comment.**
   - *Change*: the doc comment on `world::advance` overstated what the function recomputes. It is corrected, with no behaviour change.

These are unchanged from the first pass: the primitive encodings, the protocol hash and domains, tree construction, proofs and updates, `assigned_round`, the roll, the INVALID_STATE predicate and the transcript.

## Register status

1. **Commitment of a world holding an undecodable record.**
   - *Status*: resolved, in favour of the first pass's reading.
   - *Deciding text*: §7, "Malformed state carries a commitment: `encode(record)` writes each enum field as the discriminant it holds, assigned or not. A rejected transition therefore always has an input commitment to return. Decoders and proofs refuse an unassigned discriminant, and Transition 1 rejects state that holds one; the commitment does not."
   - *Corpus*: now agrees in all 88 fields.
2. **Unsorted lists.**
   - *Status*: unchanged in letter, strengthened in effect.
   - *Deciding text*: §7, "Ordering is a property of representation, not state: where an ordered representation is required, for encoding or construction, keys appear strictly ascending byte-lexicographically", together with §6's canonical form, under which anything unsorted "MUST be rejected".
   - *Why strengthened*: the new "always has an input commitment" sentence requires a commitment for these rejected inputs, and §7 defines one only over the mapping, which does not depend on order.
   - *Reading*: unchanged. The corpus agrees in all 16 cases.
3. **Repeated keys.**
   - *Status*: changed.
   - *Deciding text*: the new §7 sentence "A rejected transition therefore always has an input commitment to return" pulls against protocol.md §1, "Without uniqueness, the value at a key is undefined".
   - *Reading now*: identical repeated entries commit the mapping they denote (change 8). Conflicting records at one key have no commitment.
   - *Gap that remains*: for conflicting records, no rule supports the "always" claim. Its "therefore" draws the claim from the enum rule alone.
   - *Corpus*: not exercised.
4. **Transcript roots under world/v1.**
   - *Status*: open.
   - *Text*: §6 `TranscriptV0` and its domain `blockmon/transition/v0` are unchanged. §6 still says only "The `world_root` line above is the archived v0 derivation ... New state commits through the authenticated state tree of §7, which supersedes it." No text says that `prev_root` and `next_root` are world roots, or under which version.
   - *Reading*: unchanged. The corpus agrees in all 278 transcript hashes.
5. **What a creation writes.**
   - *Status*: open for `owner` and for the `created` increment.
   - *Text*: CREATURE_EXISTS ("creature_id(command.permit_id) is already a blockmon key") now confirms the created record's key indirectly. Its `owner` and the `supply.created` increment remain implied, not stated.
   - *Reading*: unchanged. The corpus agrees.
6. **Which root is `supply_commitment`.**
   - *Status*: open.
   - *Text*: §7 now reads "The settled artefact's `supply_commitment` is this same root, so `supply_commitment == supply_root` holds for every valid settled artefact." "This same root" still follows the `world_root` definition.
   - *Reading*: unchanged.
7. **Overflow in `assigned_round`.**
   - *Status*: open; the text is unchanged.
   - *Corpus*: not exercised.
8. **`catch_rate_bp` above 10000.**
   - *Status*: open. Only `round_period = 0` is declared an invalid manifest.
   - *Reading*: unchanged. The corpus agrees in 37 executed cases.
9. **Creature key already present.**
   - *Status*: resolved.
   - *Deciding text*: §6, `CREATURE_EXISTS creature_id(command.permit_id) is already a blockmon key`, placed after NO_CAPABILITY in the normative order, with "Reasons 1-8 and 10 are protocol semantics".
   - *Reading*: replaced (change 2). The command is now a defined rejection, evaluated before the roll.
   - *Corpus*: exercised by six cases, which agree.
10. **Validity of a `BlockmonRecord`.**
    - *Status*: open.
    - *Text*: §7 still requires "every record is valid for its domain". The proof rule speaks of "domain-local record semantics", and identifier binding is the only semantic case it lists.
    - *Corpus finding (declared)*: after the first run, the input scan showed the following. Only 6 of the 425 blockmon records in the expansion satisfy `creature_id == creature_id(origin_permit)`, and those 6 are the CREATURE_EXISTS records. So the reference does not enforce that candidate rule. The spec still does not say whether it should. My implementation already applied no such rule, so nothing changed.
    - *Other candidate*: every owner is an admitted subject, so a rule requiring that is not exercised.
11. **§3's own example breaks §3's domain rule.**
    - *Status*: open; the text is unchanged (`("blockmon/aa/v0b", "b")`).
12. **Recorded fields the specification does not define.** The status is unchanged.
    - `reads`: under the same reading (keys consulted by the checks that ran), the set now includes the blockmon key whenever CREATURE_EXISTS runs. All three hand-tier read sets agree.
    - `bound`: now records `max_keys_read: 4` and `max_keys_written: 3`. The bound is still unpinned: protocol.md §2 says only "protocol-bounded number", and the item is OPEN as Q19. My largest computed sets are 4 and 3.
    - `records`: a new expansion field, which states that no touched-key set is recorded.
    - Overall: all 18 hand-tier informational values agree, and so does the expansion `coverage` tally.

## New ambiguities

1. **Stale statements that §7 contradicts.**
   - *Text*:
     - The canonical-encoding.md preamble says "The authenticated state tree is **not** defined here (Transition 1 scope; `protocol.md` §1 OPEN)."
     - §6, under provisional stand-ins, says "`world_root` is a **flat commitment** over the canonical state bytes. The authenticated state tree remains OPEN in the protocol docket".
     - Both contradict §7 and protocol.md §1: "The authenticated state-tree structure is provisionally pinned in `canonical-encoding.md` §7".
   - *Reading*: §7 governs, by §6's own "New state commits through the authenticated state tree of §7, which supersedes it."
   - *Effect*: no computed value depends on it. I cannot tell whether this text is new, only that the first register did not record it.
2. **A committed leaf that no proof can open.**
   - *The problem*: §7 now commits state that holds an unassigned discriminant, while "Decoders and proofs refuse an unassigned discriminant". In a `Bad_Enum` world, the commanded permit's key can therefore be proved neither present nor absent. A presence proof is malformed, and an absence proof fails on the root.
   - *Consequence*: a verifier holding only commitments cannot check an INVALID_STATE rejection caused by an unassigned discriminant. No text says how such a rejection is adjudicated.
   - *Effect*: no computed value depends on it.
3. **Whole-world validity against bounded access.**
   - *The problem*: INVALID_STATE requires global sortedness, every enum field assigned, and a blockmon count equal to `created`. No bounded set of authenticated reads can establish those.
   - *Text*: protocol.md §2 concedes "The transition's own precondition reads still scan the materialised world", under OPEN Q19. It does not say which keys count as read, so what `bound` measures is unstated.
   - *Effect*: informational fields only.

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents. The sources are the same as the first pass, plus two additions:
- CREATURE_EXISTS: discriminant 10, its predicate (key presence in the blockmon domain) and its position (after NO_CAPABILITY, before the roll), all from §6.
- The update-based commitment path, which uses only §7's update definition and its full-derivation equality.

The exceptions concern the corpus format, not protocol semantics:
- the JSON representation: `0x`-prefixed lowercase hex, decimal strings for `u64` and `u32`, integers for enums, `null` for absence, and the field names;
- the `tag:0x<key>` labels and root-field names in the informational comparisons;
- the shape of the `coverage` object, including `rejected_by_reason` indexed by discriminant with slot 0 unused.

## Coverage observations

These are judged from the inputs alone. `g0c-v1/coverage_scan.py` reproduces them, and its output is in `g0c-v1/coverage-scan-pass2.txt`.

- **CREATURE_EXISTS, newly exercised.**
  - *Cases*: six, and each fails only this check.
  - *What is pinned*: three of them would have failed the roll (rolls 1319, 3392 and 7882 against rates 1, 0 and 6785). So the check's place before the roll is pinned: a kernel that tested the key only on creation would fail those three.
  - *What is not pinned*:
    - its position relative to the other preconditions;
    - key presence as the test. In every case the existing record is exactly the one a creation would write: its owner is the command subject and its origin permit is the commanded permit. A kernel that tested for "a record with this origin permit exists" would also pass.
- **Precondition precedence is mostly unpinned.**
  - *Pairings that occur*: only three genuine ones, with 8 cases each:
    - INVALID_STATE with NO_CAPABILITY;
    - INVALID_STATE with PERMIT_NOT_RESERVED;
    - UNKNOWN_SUBJECT with WRONG_SUBJECT.
  - *Apparent pairing*: the eight `round_period = 0` cases also leave `assigned_round` undefined. That pins nothing beyond the manifest rule.
  - *Swaps that would reproduce both corpora*:
    - WRONG_EPOCH and ENTROPY_MISMATCH;
    - PERMIT_NOT_RESERVED and WRONG_SUBJECT;
    - PERMIT_EXPIRED and NO_CAPABILITY;
    - NO_CAPABILITY and CREATURE_EXISTS.
  - *Covered instead by*: my unit tests.
- **The roll threshold's strictness is unpinned.** No executed case has `roll == catch_rate_bp`.
- **INVALID_STATE subclasses not exercised:**
  - an unassigned `encounter_class`;
  - a `status` other than 0, 1 or 2;
  - a repeated key in any domain, so change 8 is untested by the corpora;
  - any blockmon record rule.
  - The eight `Bad_Enum` cases all put status 0 on the commanded permit.
- **Arithmetic edges not exercised**: `assigned_round` overflow. The maxima are `round_period` 4096, margin 8 and position 1,034,582.
- **Domain shapes not exercised**: an empty subject domain or an empty permit domain. The blockmon domain is empty in 72 expansion cases and in all three hand checks.
- **Tree depth is barely exercised.** The longest shared prefix between two keys in one domain is 11 bits.
- **Proofs and authenticated updates are not recorded.** The update path, its anchoring and its rejection classes are checked only by my invariants and unit tests. Transition 1 never deletes a key, so a deletion update never runs on corpus input.
- **Only single transitions.** There are no sequences or replays. My invariant checker replays each executed command on its own output and asserts a rejection.
- **The hand tier is narrow.** It has three valid inputs, all with an empty blockmon domain, and no CREATURE_EXISTS case.
- **What is exercised, for balance** (counts are executed cases):
  - `catch_rate_bp` of 0 (15) and of 10000 or more (37);
  - `round_period` of 1 (27) and margin 0 (37);
  - the last capability (34);
  - both entropy-mismatch directions;
  - `round_period = 0`;
  - expiry at the bound;
  - unsorted lists in each domain;
  - each supply-ordering violation.

---

# G0c cleanroom report, pass 3: Transition 1 under `blockmon/world/v1`

Verbatim report of the third isolated session, 2026-10-18. The session accessed the amended `canonical-encoding.md` and `protocol.md`, both Transition 1 v1 tiers as amended after the second pass, 323 expansion cases, its own second-pass crate, and the two earlier reports. No other materials were provided. The report below was returned as the final message and is copied here unchanged.

RESULT: PASS. Every recorded value in both corpora is reproduced, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational values compared | Informational disagreements |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 18 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 323 | 8076 | 0 | 0 | 1 (the `coverage` tally) | 0 |

- **Transitions**: invariants were asserted on all 326 computed transitions, 134 executed and 192 rejected. In the expansion, 82 were CREATED, 50 ROLL_FAILED and 191 REJECTED.
- **Quality gate**, run in `impl/`:
  - `cargo fmt --check`: pass.
  - `cargo clippy --quiet --all-targets --all-features` (pedantic, nursery and cargo lints, warnings denied): pass.
  - `cargo test --release --quiet`: 55 passed, 0 failed.
- **Runs**: the first run of the updated checker already passed. Its output is `g0c-v1/first-run-pass3.txt`. The final run, `g0c-v1/final-run-pass3.txt`, is byte-identical to it.

## Files read

All paths are under STAGING (`/private/tmp/claude-501/-Users-marcotoniut-repos-games-blockmon/c68e5a5b-0b9e-4a74-bb57-f907fb710f69/scratchpad/g0c-v1-pass3`). My first command changed into STAGING, and nothing outside it was opened.

- `spec/canonical-encoding.md` and `spec/protocol.md`, in full.
- `g0c-v1/REPORT-pass1.md` and `g0c-v1/REPORT-pass2.md`, in full.
- `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml` and `.gitignore`, plus all eight files in `src/`, in full. `Cargo.lock` was listed but not opened.
- `vectors/g0a-t1-v1.json`: only by script, in two steps.
  - Before any change, I printed its top-level metadata (`tier`, `commitment_version`, `derivation`, `scenario_source`, and `bound` including its new `cost_evidence` text), its check names and the union of its check field names.
  - After the first run, `coverage_scan.py` read its inputs only.
- `vectors/g0a-t1-v1-expansion.json`: only by script, in two steps.
  - Before any change, I printed its top-level metadata (`tier`, `commitment_version`, `provenance`, `records`, `seed` and the `coverage` tally), the union of case field names and the case-name families with their counts.
  - After the first run, `coverage_scan.py` read the input fields of every case. A second script read the inputs of the `Bad_Enum`, `Status_Unassigned`, `Class_Unassigned` and `Repeated_Subject` cases.
- I never viewed a recorded output value in either corpus. Those were compared only inside the checker.

**Exposure declared.** The case-name families shown before implementing reveal what the generator targets: `order-X-before-Y` pairs, `boundary-roll-equals-rate`, `boundary-round-overflow`, `Status_Unassigned`, `Class_Unassigned` and `Repeated_Subject`. None of them decided anything. Each matching rule is stated in §6 or §7, and the existing code already implemented it. The one value-changing edit, the transcript domain, comes from the §6 text, and no family name refers to domains.

Files I wrote:
- edits to `impl/src/{t1,encoding,smt,world,invariants,corpus,kernel}.rs`. `main.rs` is unchanged.
- `g0c-v1/coverage_scan.py` (new, because the earlier passes' script is not in STAGING) and its output, `g0c-v1/coverage-scan-pass3.txt`.
- `g0c-v1/first-run-pass3.txt` and `g0c-v1/final-run-pass3.txt`.

Cargo built with the installed 1.96.0 toolchain and the local crate cache for the three declared dependencies. I opened none of those files.

## Changes from the second pass

### Made before the first run of the updated checker

1. **The transcript domain moves to v1** (`t1.rs`).
   - *Change*: `DOMAIN_TRANSITION` changes from `"blockmon/transition/v0"` to `"blockmon/transition/v1"`. Its unit test now also asserts that the v1 hash differs from the v0 hash.
   - *Text*: §6, "The `transcript_hash` above is the archived v0 derivation. In `blockmon/world/v1`, the transcript's `prev_root` and `next_root` are §7 world roots, and `transcript_hash = ProtocolHash("blockmon/transition/v1", encode(TranscriptV0))`."
   - *Effect*: this is the only change that alters computed values. It changes all 323 expansion transcript hashes.
2. **§3's boundary-shift test uses the amended example** (`encoding.rs`, test only).
   - *Change*: the test now hashes `("blockmon/aa/v1", "0b")` and `("blockmon/aa/v10", "b")` through the normal domain check. It asserts that both domains are valid, that the two naive concatenations are equal, and that the two hashes differ. The old example needed a workaround below the domain check, which is gone.
   - *Text*: §3, "`("blockmon/aa/v1", "0b")` and `("blockmon/aa/v10", "b")` hash differently even though their naive concatenations collide."
3. **A store whose work is bounded by tree depth** (`smt.rs`, `world.rs`).
   - *Change*: `smt::Store` keeps every non-empty tree node, keyed by its level and path. Reading a key's 256 siblings, or re-hashing its path, takes a fixed 256 steps whatever the domain population.
   - *Change*: `world::WorldStore` holds one `Store` per domain and is built from the full world only at genesis. In the checker each corpus case is its own genesis, as in pass 2.
   - *Change*: `WorldStore::advance` takes each touched key's siblings from the store, applies the §7 update anchored in the store's current root, then writes the new level-0 value and checks the result against the climb.
   - *Removed*: the leaf-walk `advance`, `DomainLeaves::get_mut` and `WorldCommitmentV1::field_mut`, which nothing uses any more.
   - *Text*:
     - §7 Cost: "Committing one key costs one leaf hash and 256 node hashes, independent of domain size ... The representation must bound its work by tree depth, not the occupied population."
     - protocol.md §2: "Siblings for each touched key come from the store, not a walk over the world; only genesis builds the store from the full world."
   - *Why*: the pass 2 code computed siblings for every touched key by walking the domain's whole leaf set, which scales with population.
   - *Effect*: no value changes.
4. **New invariants** (`invariants.rs`).
   - *Change*: the genesis store's commitment must equal full derivation. The commitment moved through the store must also equal full derivation of the output world.
   - *Text*:
     - protocol.md §2, "Roots and proofs are gated against the state walk".
     - §7, "The post-state root an update produces must equal the domain root of a full derivation over the post-state mapping."
5. **Conflicting records never reach the kernel** (`corpus.rs`).
   - *Change*: an input that lists one key with two different records is now reported as an input error before the kernel runs. Pass 2 ran the kernel on it and printed undefined commitments.
   - *Text*: §7, "Repeating a key with different records denotes no mapping, meaning there is no commitment and it never reaches the kernel."
6. **Unit tests.** Five new tests take the count from 50 to 55. Counting hashes in the cost test needs a hash counter, compiled only in test builds, in `encoding::framed_hash`.
   - `store_agrees_with_the_walk_for_keys_sharing_255_bits`: store siblings and roots equal the walk's through an insertion and a deletion, and an emptied store holds no nodes.
   - `moving_the_commitment_costs_the_same_at_any_population`: an executed CREATED transition costs exactly the same number of hashes in a 2-subject world as in a world of 300 extra keys. That includes a permit whose key shares 255 leading bits with the commanded permit.
   - `a_round_beyond_u64_matches_no_entropy_round`: an overflowing round gives ENTROPY_MISMATCH, while a round exactly equal to `u64::MAX` passes the check.
   - `conflicting_records_never_reach_the_kernel`.
   - `a_repeated_identical_entry_is_kernel_input`.

### Made after the first run

No mismatch prompted either of these, because the first run had none.

7. **Read proofs come from the store** (`invariants.rs`, plus `WorldStore::domain` in `world.rs`).
   - *Change*: each read key's proof now uses the siblings the store serves, and the checker asserts that they equal the walk's siblings.
   - *Prompted by*: a re-reading of protocol.md §2, "Roots and proofs are gated against the state walk". Before this, read proofs used walk siblings only, so the store's proofs were never checked.
8. **Lint and format only.** `bits % 8 != 0` became `!bits.is_multiple_of(8)` to satisfy clippy, then `cargo fmt` was applied. There is no behaviour change.

These are unchanged from pass 2: the primitive encodings, the protocol hash and its domain rule, tree construction, proof and update verification, `assigned_round`, the roll, the INVALID_STATE predicate, the precondition order, the effects of a creation, and the reading of repeated identical entries.

## Register status

**Pass 2 register**

- **2. Unsorted lists**: unchanged, and not in doubt.
  - *Deciding text*: §6, "anything else is non-canonical and MUST be rejected", together with §7, "Ordering is a property of representation, not state".
  - *Reading*: unchanged. The commitment is taken over the mapping and does not depend on listing order.
  - *Corpus*: agrees in all 16 cases.
- **3. Repeated keys**: resolved, in favour of pass 2's change 8. The gap pass 2 left for conflicting records is closed.
  - *Deciding text*: §7, "Repeating a key with an identical record denotes the mapping without the repeat. Repeating a key with different records denotes no mapping, meaning there is no commitment and it never reaches the kernel."
  - *Why the gap closes*: pass 2 found no rule behind "always has an input commitment" for conflicting records. Such input now never reaches the kernel, so it never yields a rejected transition.
  - *Change*: change 5 above.
  - *Corpus*: eight `Repeated_Subject` cases, all identical repeats, agree. Conflicting records are not exercised.
- **4. Transcript roots under world/v1**: resolved, and the reading changes.
  - *Deciding text*: §6, "In `blockmon/world/v1`, the transcript's `prev_root` and `next_root` are §7 world roots, and `transcript_hash = ProtocolHash("blockmon/transition/v1", ...)`."
  - *Change*: change 1 above. This also removes pass 1's note that the fields changed meaning without the domain suffix being bumped.
  - *Corpus*: agrees in all 323 cases.
- **5. What a creation writes**: resolved, and the reading is unchanged.
  - *Deciding text*: §6, "CREATED additionally inserts `BlockmonRecord { creature_id, owner = command.subject, origin_permit = command.permit_id }` and increments `supply.created`; ROLL_FAILED writes nothing else."
- **6. Which root is `supply_commitment`**: resolved, and the reading is unchanged.
  - *Deciding text*: §7, "`supply_commitment == supply_root` holds, because `supply_commitment` is the supply domain's root."
- **7. Overflow in `assigned_round`**: resolved, and the reading is unchanged.
  - *Deciding text*: §6, "`assigned_round` is computed exactly. If a round exceeds 2^64 − 1, it matches no `u64` `context.entropy_round`, causing the command to reject with ENTROPY_MISMATCH."
  - *Corpus*: one case, which agrees.
- **8. `catch_rate_bp` above 10000**: resolved, and the reading is unchanged.
  - *Deciding text*: §6, "A `catch_rate_bp` above 10000 is valid because every roll falls below it, so every executed attempt captures."
  - *Corpus*: 18 executed cases above 10000, which agree.
- **10. Validity of a `BlockmonRecord`**: resolved, and the reading is unchanged.
  - *Deciding text*: §6, "A `BlockmonRecord` has no validity rule beyond §7's identifier binding. Its `owner` need not be an admitted subject, and its `creature_id` need not derive from its `origin_permit`."
- **11. §3's example breaks §3's domain rule**: resolved. Both domains in the new example end in `/v<decimal>`. The test is updated (change 2).
- **12. Recorded fields the specification does not define**: the status is unchanged.
  - *`reads`*: still undefined by the spec. All three hand-tier read sets agree under pass 1's reading.
  - *`bound`*: still records `max_keys_read: 4` and `max_keys_written: 3`, and no value is pinned (protocol.md §2, OPEN Q19). It now adds a `cost_evidence` note, which is prose and is not compared. My largest computed sets are 4 and 3.
  - *`records`*: reworded to list what the expansion omits.
  - *Overall*: all 18 hand-tier informational values agree, and so does the expansion `coverage` tally.

Entries 1 and 9 were already resolved in pass 2, and their text is unchanged. Entry 1 is now exercised by 24 cases: status 0, status 3 to 255, and unassigned `encounter_class`. All 24 agree.

**Pass 2 "New ambiguities"**

- **NA1. Stale statements that §7 contradicts**: resolved.
  - *Preamble now*: "This document covers what the G0 corpora exercise: ... Transition 1 objects (§6) and the authenticated state tree (§7)."
  - *§6 stand-ins now*: "The flat `world_root` over canonical state bytes is the archived v0 stand-in. The authenticated state tree in §7 replaced it".
- **NA2. A committed leaf that no proof can open**: changed. The route for adjudicating such a rejection is now named, but a gap remains.
  - *Deciding text*: §6, "INVALID_STATE rejections are decided by re-running the transition against the complete input state, not by any proof."
  - *Remaining gap*: re-running needs that complete state in hand. §2 says "any unassigned discriminant MUST be rejected", and §7 says "Decoders and proofs refuse an unassigned discriminant". So no conforming decoder can load the very record that makes the state invalid. The snapshot chunk format is OPEN (protocol.md §12), and nothing says how such a state is carried to the party re-running it.
  - *Effect*: no computed value depends on it.
- **NA3. Whole-world validity against bounded access**: changed, from unacknowledged to declared open.
  - *Deciding text*: protocol.md §2, "The transition's own precondition reads still scan the materialised world. INVALID_STATE's validity guard also scans this. Closing Q19 makes valid input a property canonical execution preserves, checked only at genesis and snapshot import".
  - *Still open*: which keys count as read, and therefore what `bound` measures.

## New ambiguities

1. **§7's key-uniqueness clause can no longer route anything to INVALID_STATE.**
   - *Text*:
     - §7 Domain state lists "Every key is unique" among conditions whose violation "falls in the INVALID_STATE class of §6".
     - The new paragraph sends every repeat elsewhere: an identical repeat "denotes the mapping without the repeat", which violates nothing, and a conflicting repeat "never reaches the kernel".
   - *Reading*:
     - An identical repeat is INVALID_STATE through §6's canonical-form clause, because the list is not strictly ascending.
     - Conflicting records are refused before the kernel.
   - *What stays unstated*:
     - Which component refuses conflicting records, and what it returns. `WorldV0`'s `seq` encoding can express such input.
     - For an identical repeat in `blockmon`, whether "the blockmon count equals created" counts list entries or mapping keys. The outcome is INVALID_STATE either way.
   - *Effect*: no computed value depends on it.

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents, as in pass 2, with these additions:

- `blockmon/transition/v1`, from §6.
- The store uses only §7's depth, bit order, sibling order, empty ladder, `node` and `leaf`.
- Removing a node whose value equals `empty[level]` is exact rather than an assumption. A missing node is read back as `empty[level]`, so the result is the same either way.

There are two kinds of exception, and neither is protocol semantics:

- **Test-only items**: the hash counter, and the domain `blockmon/test/v0`, which one unit test uses to generate keys.
- **Corpus format, as in passes 1 and 2**:
  - the JSON representation: `0x` hex, decimal strings for `u64` and `u32`, integer enums, `null` for absence, and the field names;
  - the `tag:0x<key>` labels and root-field names in the informational comparisons;
  - the shape of the `coverage` object.

## Coverage observations

These are judged from the inputs alone. `g0c-v1/coverage_scan.py` reproduces them, and its output is `g0c-v1/coverage-scan-pass3.txt`. The expansion now pins much that earlier passes listed as open.

**Now pinned**

- **Precedence.**
  - Every adjacent pair in the normative order that can fail together is exercised:
    - INVALID_STATE and WRONG_EPOCH;
    - WRONG_EPOCH and ENTROPY_MISMATCH;
    - ENTROPY_MISMATCH and UNKNOWN_SUBJECT;
    - UNKNOWN_SUBJECT and UNKNOWN_PERMIT;
    - PERMIT_NOT_RESERVED and WRONG_SUBJECT;
    - WRONG_SUBJECT and PERMIT_EXPIRED;
    - PERMIT_EXPIRED and NO_CAPABILITY;
    - NO_CAPABILITY and CREATURE_EXISTS.
  - UNKNOWN_PERMIT and PERMIT_NOT_RESERVED cannot fail together, because the second needs the permit. The two `order-Unknown_Permit-before-Permit_Not_Reserved` cases fail UNKNOWN_PERMIT alone.
  - The order of a first-failure kernel is therefore fully determined. All four swaps pass 2 said would go undetected are now caught.
- **Roll threshold**: one executed case has `roll == catch_rate_bp` and one has `roll == catch_rate_bp − 1`, so the strict `<` is pinned.
- **Overflow** is exercised by one case.
- **Unassigned discriminants**: statuses 44, 54, 79, 86, 110, 136, 183 and 246, plus eight unassigned `encounter_class` values, alongside status 0.
- **CREATURE_EXISTS** fails in 8 cases.
  - In all 8, the existing record's `origin_permit` differs from the commanded permit, and in 5 its owner differs too. So the test for key presence is pinned against the alternative "a record with this origin permit exists".
  - In 3 of the 6 single-failure cases the roll would have failed, which pins the check's place before the roll.
- **Blockmon validity**: none of the 501 blockmon records derives from its origin permit, which is consistent with §6's new "need not derive".

**Not exercised**

- An unassigned discriminant on a permit other than the commanded one. In all 24 cases it sits on the commanded permit, so a kernel that validated enums only on the permit it reads would pass.
- Repeated keys in `blockmon` or `permits`, and conflicting records anywhere. Conflicting records cannot occur for subjects, because `SubjectV0` is unit.
- A blockmon owner who is not an admitted subject. All 501 owners are admitted.
- An empty subject or permit domain.
- Keys sharing long prefixes: the longest shared prefix within a domain is 11 bits. My unit tests cover 255.
- A non-zero supply key, which `WorldV0` cannot express.
- Proofs, authenticated updates and deletions, which are not recorded. The `records` field says so.
- Sequences or replays: every case is a single transition.

**Hand tier**: still three checks, all with an empty blockmon domain.

**Exercised, for balance** (counts are executed cases):
- `catch_rate_bp` of 0 (15), of 10000 or more (37), and above 10000 (18);
- `round_period` of 1 (27) and margin 0 (37);
- the last capability (34);
- an empty blockmon domain (40 executed, 80 in all).

---

# G0c cleanroom report, pass 4: Transition 1 under `blockmon/world/v1`

Verbatim report of the fourth isolated session, 2026-10-18. Inputs included the amended `canonical-encoding.md` and `protocol.md`, its own third-pass crate, the three earlier reports, and both Transition 1 v1 tiers as amended after the third pass. No other inputs were provided. The context carried two recent commit subjects, which the report declares. The report was returned as the final message and is copied here unchanged.

## RESULT

**PASS.** Every recorded value in both corpora is reproduced, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational compared | Informational disagreements |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 12 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 323 | 8076 | 0 | 0 | 1 (the `coverage` tally) | 0 |

- **Transitions**: invariants were asserted on all 326 computed transitions, 134 executed and 192 rejected.
- **Informational count**: the hand tier's count fell from 18 to 12 because the corpus no longer records `reads` or `keys_read`.
- **Quality gate**, run from `impl/` with the exact commands given:
  - `cargo fmt --check` passes.
  - `cargo clippy --quiet --all-targets --all-features` passes (pedantic, nursery and cargo lints, warnings denied).
  - `cargo test --release --quiet`: 57 passed, 0 failed.
- **Runs**: the first run of the updated checker already passed. Its output is `g0c-v1/first-run-pass4.txt`. The final run, `g0c-v1/final-run-pass4.txt`, is byte-identical to it.

## Files read

All paths are under STAGING (`/private/tmp/claude-501/-Users-marcotoniut-repos-games-blockmon/c68e5a5b-0b9e-4a74-bb57-f907fb710f69/scratchpad/g0c-v1-pass4`). My first command changed into STAGING.

- `spec/canonical-encoding.md` and `spec/protocol.md`, in full.
- `g0c-v1/REPORT-pass1.md`, `REPORT-pass2.md` and `REPORT-pass3.md`, in full.
- `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `.gitignore`, and all eight files in `src/`, in full. `Cargo.lock` was listed but not opened.
- `vectors/g0a-t1-v1.json`, by script only:
  - Before any change: the top-level metadata (`tier`, `commitment_version`, `derivation`, `scenario_source`), the check names, the field names of each check, and the member names of `input` and `output`.
  - After the first run: `coverage_scan.py` read the inputs only.
- `vectors/g0a-t1-v1-expansion.json`, by script only:
  - Before any change: the metadata (`tier`, `commitment_version`, `provenance`, `records`, `seed` and the recorded `coverage` tally), the sets of case field names, and the case-name families with their counts.
  - After the first run: `coverage_scan.py` read the inputs only.
- I never viewed a recorded output value in either corpus. They were compared only inside the checker.

**Exposure declared.**
- The harness attached session context before I started. It included recent commit subjects from the repository: "fix(conformance): drop the hand tier's undefined read fields, and route repeated keys" and "fix(protocol): close the second cleanroom pass's register".
- I opened nothing outside STAGING, but that text was in my context.
- It decided nothing. I found the dropped fields by scanning field names, and the routing of repeated keys comes from the §7 text quoted below.
- I also saw the expansion's recorded `coverage` tally, as pass 3 did. It is identical to pass 3's figures and decided nothing.

**Files I wrote:**
- edits to `impl/src/{smt,world,invariants,corpus}.rs`; `t1.rs`, `kernel.rs`, `encoding.rs` and `main.rs` are unchanged;
- `g0c-v1/coverage_scan.py`, new because pass 3's script is not in STAGING, and its output `g0c-v1/coverage-scan-pass4.txt`;
- `g0c-v1/first-run-pass4.txt` and `g0c-v1/final-run-pass4.txt`.

Cargo used the installed 1.96.0 toolchain and the local crate cache.

## Changes from the third pass

None of these changes alters a computed protocol value.

### Made before the first run of the updated checker

1. **The hand tier's read fields are no longer compared** (`corpus.rs`).
   - *Corpus change*: the field scan showed that `reads` and `keys_read` are gone from every check, and the top-level `bound` (with its `cost_evidence`) is gone.
   - *Change*: the `reads (as a set)` and `keys_read` comparisons are removed, and both names are dropped from `HAND_HANDLED`. If they reappear, the checker lists them as "recorded but not compared".
   - *Spec*: no text defines a read set. protocol.md §2 leaves it under OPEN Q19.
   - *Retained*: the kernel still keeps its read list, but only to drive the read-proof invariants.
2. **The producer climbs once per key** (`world.rs`, `smt.rs`).
   - *Text*, §7 Cost:
     - "Committing one key costs one leaf hash and 256 node hashes ... A state-changing transition costs that per key touched, plus one `blockmon/world/v1` recomputation."
     - "Verification cost is accounted separately."
     - "A producer with the domain state already knows the pre-state root and climbs once."
   - *What pass 3 did*: its `advance` ran a full anchored update plus a store write, which is 3 leaf hashes and 3 climbs per key. Its cost test allowed that.
   - *Change*:
     - `WorldStore` now holds each domain's records beside its tree, which is the domain state.
     - `advance` refuses an old value the state does not hold, by comparing bytes with no hash. It then computes the new leaf and climbs once through the store.
     - The anchored two-climb path is now `WorldStore::verify_updates`, which only the invariants use.
     - A new `smt::admitted_level_zero` applies the key and record malformed classes without climbing.
   - *Tests*:
     - `moving_the_commitment_costs_the_same_at_any_population` now asserts exactly `3 * (1 + 256) + 1` hashes for a CREATED transition, at 2 keys and at 300+ keys.
     - New `an_anchored_update_costs_two_leaf_hashes_and_two_climbs` asserts `2 + 512` for the verifier ("two leaf hashes and 512 node hashes per key").
   - I cannot tell whether this text is new. Pass 3 does not quote it.
3. **Verifier-side invariants** (`invariants.rs`).
   - *Change*: for each declared write, the pre-state store's siblings must equal the walk's. The producer's move and the anchored verification must each reach the full derivation.
   - *Text*:
     - protocol.md §2, "Roots and proofs are gated against the state walk".
     - §7, "The post-state root an update produces must equal the domain root of a full derivation over the post-state mapping."
4. **Decoding refuses conflicting records** (`corpus.rs` `parse_world`, new `world::conflicting_key`).
   - *Text*: §7, "Repeated keys with different records denote no mapping; decoding refuses them, so they have no commitment and never reach the kernel."
   - *Change*: pass 3 refused these at store genesis. The refusal now happens at decoding, with no hashing, and the result is still an input error before the kernel runs.
   - *Identical repeats*: unchanged. They pass decoding and reach the kernel as INVALID_STATE, per "the listing remains non-canonical, so Transition 1 rejects it as INVALID_STATE".
5. **Tests.** Two tests are new, taking the count from 55 to 57. The tests touched by changes 2 and 4 were updated to match.

### Made after the first run

No mismatch prompted this change, because the first run had none.

6. **The producer applies the malformed classes to the old value too** (`smt.rs`, `world.rs`).
   - *Prompted by*: re-reading §7, "An update's rejection classes are those of a proof, applied to both of its values", during register review.
   - *Change*: record checking (`check_record`, no hash) is split from leaf hashing. `admitted_level_zero` now takes both values. `advance` checks malformedness first and the anchor second, the same order as `apply_update`.
   - *Test*: a new assertion checks that a write whose old permit holds status 0 is refused as Malformed and leaves the commitment unmoved. The final run is byte-identical to the first.

**Unchanged from pass 3:**
- the primitive encodings, the hash and its domain rule, and tree construction;
- proof and update verification, `assigned_round` and the roll;
- the INVALID_STATE predicate and the precondition order;
- the effects of a transition and the `transition/v1` transcript domain.

## Register status

**Entries pass 3 left open**

- **2. Unsorted lists**: unchanged, and not in doubt.
  - *Deciding text*: §6, "anything else is non-canonical and MUST be rejected", and §7, "Ordering is a property of representation, not state".
  - *Supporting text*: the new repeat sentence applies the same principle. A non-canonical listing of a denoted mapping is INVALID_STATE, and its commitment is taken over the mapping.
  - *Corpus*: agrees in all 16 cases.
- **12. Recorded fields the spec does not define**: changed. The hand tier dropped `reads`, `keys_read` and `bound`.
  - *Still compared informationally*: `rejected`, `roots_unchanged`, `writes` and `keys_written` (12 values), and the expansion `coverage` tally. All agree.
  - *`writes`*: its content is fixed by §6, "ROLL_FAILED writes nothing else", but its representation is corpus format.
  - *Reads*: what counts as a read is still unstated. That is spec-declared OPEN (protocol.md §2, Q19), and the corpus no longer depends on it.

**Pass 2 "New ambiguities"**

- **NA2. A committed leaf that no proof can open**: still open, with no change in substance.
  - *Text*: §6, "INVALID_STATE rejections are decided by re-running the transition against the complete input state, not by any proof". §7 still says "Decoders and proofs refuse an unassigned discriminant".
  - *Spec-declared OPEN part*: how the complete state is carried. The chunk format is "OPEN: chunk format" (protocol.md §12, and the docket's "Still unwritten").
  - *Genuine gap*: §1 says "Decoders MUST reject every non-canonical form". So even once a chunk format exists, a conforming decoder cannot load the state that must be re-run.
- **NA3. Whole-world validity against bounded access**: still open, spec-declared OPEN (Q19). The text is unchanged. With `reads` and `bound` gone from the corpus, the question no longer touches any recorded field.

**Pass 3 new ambiguity 1 (the key-uniqueness clause routes nothing)**: changed, and mostly resolved.
- *Resolved*: the amended sentence states pass 3's reading outright. An identical repeat "remains non-canonical, so Transition 1 rejects it as INVALID_STATE". It also names the component that refuses conflicting records: "decoding refuses them".
- *Genuine gaps that remain, neither affecting a value*:
  - §7 Domain state's "Every key is unique ... falls in the INVALID_STATE class" still has no case to route, so it is redundant.
  - What decoding returns on refusal is unstated.
  - For an identical repeat in `blockmon`, "the blockmon count equals created" can count either list entries or mapping keys. The outcome is INVALID_STATE either way.

**Entries pass 3 resolved, rechecked**

These are still decided by text present in the amended spec:
- 4: §6, "transcript_hash = ProtocolHash("blockmon/transition/v1", ...)";
- 5: §6, "Executed attempts set ... CREATED additionally inserts ...";
- 6: §7, "supply_commitment == supply_root holds, because supply_commitment is the supply domain's root";
- 7: §6, overflow gives ENTROPY_MISMATCH;
- 8: §6, a `catch_rate_bp` above 10000 is valid;
- 10: §6, "no validity rule beyond §7's identifier binding";
- 11: §3, the `aa/v1` and `aa/v10` example.

Entry 3 (repeated keys) is now decided by the amended sentence above. The reading is unchanged, and only the refusing component moved (change 4). The 8 `Repeated_Subject` cases agree.

## New ambiguities

1. **"decoding refuses them" conflicts with §1's decoders.**
   - *The tension*: §1 says "Decoders MUST reject every non-canonical form; 'lenient reader' implementations are non-conforming", and §7 says "Decoders ... refuse an unassigned discriminant". Yet §6 and §7 route unsorted listings, identical repeats and unassigned discriminants to the kernel as INVALID_STATE. The amended sentence says decoding refuses only conflicting repeats.
   - *Consequence*: the kernel-input reader must admit three non-canonical forms and refuse one, which is what §1 calls non-conforming.
   - *My reading*: "decoding" here means reading a listing into the state mapping, the one step that cannot represent conflicting records. The strict wire decoder is a separate, stricter step.
   - *Effect*: no computed value depends on it.
2. **Precedence between Malformed and Invalid.** Take an update whose new value is malformed and whose old value does not anchor.
   - *The tension*: the procedural text climbs the old value before it computes the new one. The rejection table makes the two classes "distinct outcomes", but states no precedence.
   - *My reading*: malformedness is decided first, since "An update's rejection classes are those of a proof, applied to both of its values".
   - *Effect*: not exercised by either corpus.
3. **Whether a producer checks its old value.** "Climbs once" and "one leaf hash ... per key" rule out hashing the old value.
   - *The gap*: protocol.md §2 describes the reference store as holding "one locator per key with its leaf commitment", not records. A producer holding only commitments could therefore not check its old value at the stated cost. The text does not say whether a producer checks it at all.
   - *My choice*: compare the old value against held records, which costs no hash (change 2).

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents, as in pass 3. The producer and verifier split uses only §7's update definition and its cost statements.

The exceptions are not protocol semantics:
- **Test-only items**: the hash counter, and the domain `blockmon/test/v0`, which one test uses to generate keys.
- **Corpus format**:
  - the JSON representation: `0x` hex, decimal strings for `u64` and `u32`, integer enums, `null` for absence, and the field names;
  - the `tag:0x<key>` labels and root-field names in the informational comparisons;
  - the shape of the `coverage` object.

## Coverage observations

These are judged from the inputs alone. `g0c-v1/coverage-scan-pass4.txt` holds the scan output. The expansion's inputs show the same coverage as pass 3 recorded; only the hand tier changed.

**Pinned**
- Every adjacent precondition pair that can fail together.
- The strict roll threshold: one executed case has the roll equal to the rate, and one has it one below.
- One `assigned_round` overflow case.
- CREATURE_EXISTS:
  - In all 8 cases, the existing record's origin permit differs from the commanded permit, and in 5 its owner differs too.
  - In 3 of the 6 single-failure cases the roll would have failed, which pins the check's place before the roll.

**Not exercised**
- An unassigned discriminant on a permit other than the commanded one. All 24 cases put it on the commanded permit.
- Repeated keys in `blockmon` or `permits`. Only 8 identical subject repeats occur.
- Conflicting records, so the new decoding refusal is untested by any corpus.
- A blockmon owner who is not an admitted subject. All 501 owners are admitted, and no `creature_id` derives from its origin permit.
- An empty subject or permit domain.
- Long shared key prefixes: at most 11 bits in the expansion and 1 in the hand tier.
- Proofs, authenticated updates and deletions; the producer and verifier cost split; the precedence between Malformed and Invalid.
- Any sequence of transitions.
- Any read set: the hand tier no longer records one.

**Hand tier**: three checks, all with an empty blockmon domain.

---

# G0c cleanroom report, pass 5: Transition 1 under `blockmon/world/v1`

Verbatim report of the fifth isolated session, 2026-10-18. Inputs were the two amended specification documents, the two Transition 1 v1 tiers as amended after the fourth pass, the fourth-pass crate, and the four earlier reports. No other inputs. The context included recent commit subjects and a memory note, which the session declares. The report was returned as the final message and is reproduced here unchanged.

## RESULT

**PASS.** Every recorded value in both corpora is reproduced, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational compared | Informational disagreements |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 12 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 323 | 8076 | 0 | 0 | 1 (the `coverage` tally) | 0 |

- **Transitions**: invariants were asserted on all 326 computed transitions.
  - Hand tier: 1 created, 1 roll failed, 1 rejected.
  - Expansion: 82 created, 50 roll failed, 191 rejected.
- **Quality gate**, run from `impl/` with the exact commands given:
  - `cargo fmt --check` passes.
  - `cargo clippy --quiet --all-targets --all-features` passes (pedantic, nursery and cargo lints, warnings denied).
  - `cargo test --release --quiet`: 59 passed, 0 failed.
- **Runs**: the first run of the updated checker already passed (`g0c-v1/first-run-pass5.txt`). The final run (`g0c-v1/final-run-pass5.txt`) differs only by one added reporting line per corpus (change 7).

## Files read

All paths are under STAGING (`/private/tmp/claude-501/-Users-marcotoniut-repos-games-blockmon/c68e5a5b-0b9e-4a74-bb57-f907fb710f69/scratchpad/g0c-v1-pass5`). My first command changed into STAGING, and I opened nothing outside it.

- `spec/canonical-encoding.md` and `spec/protocol.md`, in full.
- `g0c-v1/REPORT-pass1.md` to `REPORT-pass4.md`, in full.
- `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `.gitignore` and all eight files in `src/`, in full. `Cargo.lock` was listed but not opened.
- Both vector files, by script only:
  - **Before any change**: the top-level metadata (`tier`, `commitment_version`, `derivation`, `scenario_source`, `provenance`, `records`, `seed`) and the field names of cases and their sub-objects. I did not print the `coverage` tally. The field sets match pass 4's.
  - **After the first run**: `g0c-v1/coverage_scan.py` read only `name`, `input_state`, `command`, `context` and `manifest`.
- During a mutation check (end of the next section), the checker printed invariant lines that name cases. No recorded value was shown.
- I never viewed a recorded output value. Recorded outputs were compared only inside the checker.

**Exposure declared.** None of the following decided anything.
- The harness attached the repository's recent commit subjects to my context. They include "docs(encoding): state reader, update precedence, and producer's minimum cost", "feat(conformance): G0c-v1 fourth pass", "fix(conformance): drop the hand tier's undefined read fields, and route repeated keys", "test(conformance): mutations for register amendments and cleanroom catcher" and a build commit. The git status was also attached.
- The first subject names the three amended areas. I still re-read both documents in full, and found each amendment by comparing the current text with the passages pass 4 quotes.
- A user memory note mentions blockmon's Rust lint conventions.

**Files I wrote**
- Edits to all eight files in `impl/src/`.
- `g0c-v1/coverage_scan.py` (new, because pass 4's script is not in STAGING) and its output `g0c-v1/coverage-scan-pass5.txt`.
- `g0c-v1/first-run-pass5.txt` and `g0c-v1/final-run-pass5.txt`.
- A temporary string-replacement helper under `g0c-v1/tools/`, since deleted.

## Changes from the fourth pass

No change alters a computed protocol value.

### Made before the first run of the updated checker

1. **The §6 state reader is explicit** (`world.rs`: `read_state`, `ReadError`; `t1.rs`: `WorldV0::read_listing` and per-record `decode_from`).
   - *Text*:
     - §6: "The state reader, rather than the strict decoder from §2, handles kernel input. It maps listings to semantic values and accepts the forms that INVALID_STATE rejects: unsorted listings, identical repeated keys, and unassigned enum discriminants. The reader only refuses listings that denote no mapping."
     - §1: "The §6 state reader is the sole exception; it reads Transition 1 kernel input."
     - §7: "the §6 state reader refuses them, so they carry no commitment and never reach the kernel."
   - *Change*:
     - Corpus input now flows from the JSON listing, to its §2 encoding, through `read_state`, to the kernel.
     - Pass 4 refused conflicting records inside `parse_world` under the name "decoding". The refusal now comes from the reader.
2. **A strict `WorldV0` decoder for wire objects** (`t1.rs`: `WorldV0::decode` and `DecodeError::NonCanonicalOrder`).
   - *Text*:
     - §6: "Wire objects remain under the strict decoder from §2."
     - §6 canonical form: "anything else is non-canonical and MUST be rejected."
     - §1: "Decoders MUST reject every non-canonical form."
   - *Code moves*:
     - `strictly_ascending` moves from `kernel.rs` to `t1.rs`.
     - `Decoder::u32`, `length` and `seq` are no longer test-only.
   - *Use*: the strict decoder computes no value. Only change 3 uses it.
3. **Reader invariants** (`invariants.rs`: `check_reading`, which replaces pass 4's plain determinism re-run). On every transition it asserts the following.
   - The reader returns the kernel input unchanged from its encoding.
   - A re-run on the state as read again reproduces the transition. *Text*: §6, "A re-run of an INVALID_STATE rejection reads the input state in the same way."
   - When the strict decoder refuses the input, the outcome is INVALID_STATE. When it accepts, it returns the same listing. *Text*: the reader "accepts the forms that INVALID_STATE rejects".
4. **Precedence tests** (`smt.rs`: new `malformed_takes_precedence_over_an_unanchored_old_value`; `world.rs`: a producer-path case).
   - *Text*: §7, "Malformed takes precedence. Because shape and admissibility are checked before the anchoring climb, an update that is both malformed and unanchored is rejected as Malformed."
   - *Cases*:
     - In `smt.rs`, each of these is paired with an unanchored old value: a misbound new record, a truncated old record, a short sibling sequence and a non-zero supply key.
     - In `world.rs`, a malformed new value is paired with an old value that is not held.
   - *Behaviour*: unchanged, because pass 4 already decided malformedness first.
5. **Cost test** (`world.rs`: `moving_the_commitment_costs_the_same_at_any_population`).
   - *Text*: §7, "That is the producer's minimum. Implementations may additionally anchor each update at the verifier's cost and spend further depth-bounded work maintaining their representation. Both costs are independent of domain size."
   - *Change*: the test now also measures the anchored path at 2 and 300+ keys. It asserts that the anchored cost is the same at both sizes and exceeds the producer's cost.
   - *Kept*: the producer's cost is still exactly `3 * (1 + 256) + 1`, and the `advance` doc comment now names it as the minimum.
6. **New test `the_state_reader_keeps_what_invalid_state_rejects`.**
   - An unsorted listing, an identical repeat and a status 0 permit are each refused by the strict decoder (`NonCanonicalOrder`, `NonCanonicalOrder`, `UnassignedEnum(0)`).
   - The reader returns each listing as given, the kernel rejects each as INVALID_STATE, and the invariants report nothing.
   - The reader refuses a conflicting repeat as `NoMapping`, and a trailing byte or a truncation as `Structure`.
   - With changes 4 and 6, the test count goes from 57 to 59.

### Made after the first run

7. **Reporting only**: each corpus now prints its computed outcome counts (`corpus.rs` `Tally.outcomes`, `main.rs`). No mismatch prompted it, because there was none. I added it to report the transition counts.

**Mutation check.** I temporarily disabled the kernel's subject-order check. The new strict-decoder invariant then flagged every `Unsorted_Subjects` and `Repeated_Subject` case. I restored the file, and the final run is unchanged.

**Unchanged:**
- primitive encodings, the hash and its domains, and tree construction;
- proof and update verification, `assigned_round` and the roll;
- the INVALID_STATE predicate and the precondition order;
- effects and the `transition/v1` transcript domain.

## Register status

**Entries pass 3 left open (pass 4's register)**

- **2. Unsorted lists**: not in doubt, and now stated outright. §6: the reader "accepts the forms that INVALID_STATE rejects: unsorted listings". The corpus agrees in all 16 cases.
- **12. Recorded fields the spec does not define**: unchanged.
  - The hand tier's `rejected`, `roots_unchanged`, `writes` and `keys_written` (12 values) and the expansion's `coverage` tally are compared informationally, and all agree.
  - What counts as a read stays OPEN in the spec itself (protocol.md §2, Q19), and nothing recorded depends on it.

**Pass 2 NA2 (a committed leaf that no proof can open)**: changed, and its genuine gap is resolved.
- *Resolved*: pass 4's gap was that no conforming decoder could load the state that must be re-run. §1 now reads "The §6 state reader is the sole exception; it reads Transition 1 kernel input", and §6 reads "A re-run of an INVALID_STATE rejection reads the input state in the same way."
- *Still open, but declared OPEN by the spec*: how the complete state reaches the party re-running it ("OPEN: chunk format", protocol.md §12, and the docket's "checkpoint/snapshot chunk format").
- *By design, not a gap*: "Decoders and proofs refuse an unassigned discriminant" still means no proof opens such a leaf. §6 routes these rejections to the re-run, so that is intended.

**Pass 2 NA3 (whole-world validity against bounded access)**: unchanged, and declared OPEN by the spec (Q19): "INVALID_STATE's validity guard also scans this. Closing Q19 makes valid input a property canonical execution preserves".

**Pass 3 NA1 (the key-uniqueness clause routes nothing)**: three sub-gaps were left.
- **(a) §7's "Every key is unique ... falls in the INVALID_STATE class" is redundant**: unchanged. It is a genuine gap but harmless. The reader maps identical repeats to "a single entry" and refuses conflicting ones, so no mapping can violate uniqueness.
- **(b) What a refusal returns**: changed, and partly resolved.
  - *Resolved*: the refusing component is now named: "the §6 state reader refuses them" and "The reader only refuses listings that denote no mapping".
  - *Still a genuine gap*: what the refusal produces is unstated. It affects no value, because such input never reaches the kernel and so has no transition or transcript.
- **(c) Counting entries or keys for "the blockmon count equals created"**: unchanged in effect. "Repeated keys with identical records map to a single entry" now favours counting the mapping. The listing is non-canonical, so the outcome is INVALID_STATE either way. It is not exercised.

**Pass 4 new ambiguities**

1. **"decoding refuses them" against §1's strict decoders**: resolved, in favour of pass 4's reading.
   - *Deciding text*: §1, "The §6 state reader is the sole exception"; §7, "the §6 state reader refuses them"; §6, "Wire objects remain under the strict decoder from §2".
   - *Implemented by*: changes 1 to 3.
2. **Precedence between Malformed and Invalid**: resolved, in favour of pass 4's reading.
   - *Deciding text*: §7, "Malformed takes precedence ... an update that is both malformed and unanchored is rejected as Malformed".
   - *Implemented by*: change 4, which adds tests only.
3. **Whether a producer checks its old value**: changed, and largely resolved.
   - *Resolved*: "That is the producer's minimum. Implementations may additionally anchor each update at the verifier's cost". So anchoring is optional work above the minimum, and a producer need not climb its old value.
   - *Kept*: pass 4's hash-free comparison against held records remains, as permitted extra work.
   - *Minor remainder, no value effect*: protocol.md §2 still describes the reference store as holding "one locator per key with its leaf commitment", while §7's producer holds "the domain state", which is records.

**Entries pass 3 resolved, rechecked**: entries 3 to 8, 10 and 11 are still decided by text present in the amended documents. Entry 3's sentence is reworded, but the reading is unchanged.

## New ambiguities

1. **Bytes that are not a listing.**
   - *The gap*: "The reader only refuses listings that denote no mapping" leaves no stated ground for refusing truncated input, trailing bytes or a count that exceeds the input. Yet the accepted forms are named as only the three that INVALID_STATE rejects.
   - *My reading*: the reader keeps §2's structural rules, since such bytes are not a listing. Its leniency covers only the three named forms.
   - *Effect*: none. The corpora are JSON.
2. **What the kernel receives.**
   - *The tension*: the reader "maps listings to semantic values", but Transition 1 must still see that "the listing stays non-canonical". A reader that output only the mapping would hide unsorted and repeated listings from INVALID_STATE.
   - *My reading*: kernel input stays the `WorldV0` listing as read, and the semantic mapping is what the commitment is taken over.
   - *Effect*: none.

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents. The new elements come from §6, §7 and §1:
- the reader's accepted forms and its one refusal;
- the strict decoder's refusals;
- Malformed precedence;
- the producer's minimum.

`NonCanonicalOrder` is an error label, not a protocol value.

The exceptions are not protocol semantics:
- **Test-only items**: the hash counter, and the domain `blockmon/test/v0` used to generate keys.
- **Corpus format**:
  - the JSON representation: `0x` hex, decimal strings for `u64` and `u32`, integer enums, `null` for absence, and the field names;
  - the `tag:0x<key>` labels and root-field names in the informational comparisons;
  - the shape of the `coverage` object.

## Coverage observations

These are judged from the inputs alone (`g0c-v1/coverage-scan-pass5.txt`). The figures are the same as pass 4 recorded.

**State reader**
- *Exercised*: 48 expansion cases carry a form the reader accepts and the strict decoder refuses, and all are INVALID_STATE. No case combines two forms.
  - 16 unsorted listings: 6 subjects, 4 blockmon, 6 permits.
  - 8 identical subject repeats.
  - 24 unassigned discriminants: status 0 eight times, eight other statuses, and eight `encounter_class` values.
- *Not exercised*:
  - the reader's only refusal, conflicting records;
  - its structural behaviour, since the corpora are JSON;
  - identical repeats in `blockmon` or `permits`;
  - an unassigned discriminant on a permit other than the commanded one (all 24 sit on the commanded permit).

**Still pinned**
- All eight adjacent precondition pairs.
- The strict roll threshold: one executed case has the roll equal to the rate, and one has it one below.
- One `assigned_round` overflow.
- 18 executed cases with `catch_rate_bp` above 10000.
- CREATURE_EXISTS in 8 cases.

**Not exercised**
- Proofs, authenticated updates, deletions, Malformed precedence and the cost split between producer and verifier: none of them is recorded.
- Re-runs and sequences: every case is a single transition.
- A blockmon owner who is not an admitted subject, and a `creature_id` derived from its origin permit: 0 of 501 records.
- An empty subject or permit domain.
- Long shared key prefixes: at most 11 bits in the expansion and 1 bit in the hand tier.

**Hand tier**: three checks, all with an empty blockmon domain: two executed and one PERMIT_EXPIRED rejection.

---

# G0c cleanroom report, pass 6: Transition 1 under `blockmon/world/v1`

Record of the sixth isolated session, 2026-10-19. Inputs comprised the two amended specification documents, the two Transition 1 v1 tiers as amended after the fifth pass, the fifth-pass crate, and the five earlier reports. Nothing else was provided. The report notes other items in its context: recent commit subjects and a memory note, plus three small slips outside its directory that read nothing. The report was returned as the final message and copied here unchanged.

## RESULT

**PASS.** Every recorded value in both corpora is reproduced, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational compared | Informational disagreements |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 12 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 344 | 8601 | 0 | 0 | 1 (the `coverage` tally) | 0 |

- **Transitions**: invariants were asserted on all 347 computed transitions.
  - Hand tier: 1 created, 1 roll failed, 1 rejected.
  - Expansion: 82 created, 50 roll failed, 212 rejected.
  - The state reader refused no case in either corpus.
- **Quality gate**, run from `impl/` with the exact commands given:
  - `cargo fmt --check` passes.
  - `cargo clippy --quiet --all-targets --all-features` passes (pedantic, nursery and cargo lints, warnings denied).
  - `cargo test --release --quiet`: 61 passed, 0 failed.
- **Runs**: the first run of the updated checker passed (`g0c-v1/first-run-pass6.txt`). The final run (`g0c-v1/final-run-pass6.txt`) is byte-identical to it.

## Files read

All paths are under STAGING (`/private/tmp/claude-501/-Users-marcotoniut-repos-games-blockmon/c68e5a5b-0b9e-4a74-bb57-f907fb710f69/scratchpad/g0c-v1-pass6`). My first command changed into STAGING.

- `spec/canonical-encoding.md` and `spec/protocol.md`, in full.
- `g0c-v1/REPORT-pass1.md` to `REPORT-pass5.md`, in full.
- `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `.gitignore` and all eight files in `src/`, in full. `Cargo.lock` was listed but not opened.
- Both vector files, by script only:
  - **Before any change**: the top-level metadata (`tier`, `commitment_version`, `derivation`, `scenario_source`, `provenance`, `records`, `seed`), the field names of cases and their sub-objects, and the case-name families with their counts. I did not print the `coverage` tally.
  - **After the first run**: `g0c-v1/coverage_scan.py` read only `name`, `input_state`, `command`, `context` and `manifest`. Two short scripts read the same fields for the new families.
  - **Mutation runs**: I printed only case names, field names and counts.
- I never viewed a recorded output value.

**Exposure declared.** None of the following decided anything.
- **Harness context**: the harness attached the repository's git status and recent commit subjects to my context. The subjects are:
  - "docs: close the wording the fifth cleanroom pass left open"
  - "feat(conformance): close coverage gaps from fifth cleanroom pass"
  - "docs(conformance): clarify that a tree proof's leaf is not part of the proof"
  - "ci: run the mutation harness weekly"
  - "test(conformance): cross-target covers the Transition 1 corpus"
- **Memory note**: a user memory note mentions blockmon's Rust lint conventions.
- **How I found the amendments instead**:
  - I re-read both documents in full.
  - `g0c-v1/quote_diff.py` checks every passage the five reports quote against the current text.
  - I found the new families from the family scan.
- **Case family names**: these show what the generator targets.
- **Slips**:
  - A throwaway mutant run's stdout was redirected to `/tmp/null_guard_unused`, outside STAGING. I never viewed it and deleted it at once.
  - A stray `git -C . status` from `impl/` answered "not a git repository" and read nothing.
  - The harness saved one long `cat` of `smt.rs` to its own tool-results file outside STAGING. I did not open that file; I re-read `smt.rs` in STAGING instead.

**Files I wrote**
- Edits to `impl/src/{corpus,main,world,kernel}.rs`. The files `t1.rs`, `smt.rs`, `encoding.rs` and `invariants.rs` are unchanged.
- `g0c-v1/quote_diff.py`, `g0c-v1/coverage_scan.py` and `g0c-v1/coverage-scan-pass6.txt`.
- `g0c-v1/first-run-pass6.txt` and `g0c-v1/final-run-pass6.txt`.
- `g0c-v1/mutant/`, a temporary copy of the crate for two mutation checks, since deleted.

## Changes from the fifth pass

All changes were made before the first run of the updated checker. None alters a computed protocol value, and the first run prompted no change.

1. **A state-reader refusal is a defined result, not an input error** (`corpus.rs`, `main.rs`).
   - *Text*: §6, "The state reader enforces §2's structural rules, rejecting input that is not a listing, such as truncation or trailing bytes." Also §6, "Because refusal occurs before any transition, it produces no outcome, commitment, or transcript."
   - *Change*:
     - `compute` now returns `Unrun::Input` for JSON that does not describe kernel input, and `Unrun::Refused` when `world::read_state` refuses the listing. `parse_world` is split into `parse_listing`, which parses JSON only, and the reader call.
     - A refused case compares each spec-defined output it records against "none". Those are the hand tier's `outcome`, `effects`, `output_state`, `input` and `output`, and the expansion's `input_commitment`, `effects`, `output_state`, `output_commitment` and `transcript_hash`. Each agrees only if it is absent or `null`.
     - `manifest_hash` and `command_hash` are still compared on a refused case, since neither depends on the state.
     - Each corpus now prints its refused count.
   - *Before*: pass 5 reported a refusal as an input error, which failed the run whatever the case recorded.
2. **Doc comment on `world::read_state`**: it now names both refusals and says the kernel receives the listing as read.
   - *Text*: §6, "The kernel processes the listing as read, taking commitment over the mapping it denotes."
3. **Tests** (59 to 61):
   - **`corpus.rs`**:
     - `conflicting_records_never_reach_the_kernel` now expects `Unrun::Refused` and checks that no outcome was tallied.
     - New `a_refusal_agrees_only_with_recorded_absence`.
   - **`kernel.rs`**:
     - `invalid_state_classes` adds an unassigned status on a permit other than the commanded one. *Text*: §6, "every enum field holds an assigned value".
     - The same test adds an identical blockmon repeat, once with `created` equal to the mapping's key count and once to the entry count. *Text*: §7, "the listing stays non-canonical, causing Transition 1 to reject it as INVALID_STATE".
     - New `empty_domains_reject_by_absence`: an empty subject domain gives UNKNOWN_SUBJECT, and an empty permit domain gives UNKNOWN_PERMIT.
   - **`world.rs`**:
     - `a_repeated_identical_entry_commits_its_mapping` adds a blockmon repeat. *Text*: §7, "Repeated keys with identical records map to a single entry".
     - `advancing_by_the_kernel_writes_matches_full_derivation` refuses the second write. Both the producer path and the anchored path must then leave the supply root at its pre-state value. *Text*: §7, "A rejected update leaves the domain root at its pre-state value."

**Needed no change**: §7, "It contains no leaf hash or path data. The verifier computes the leaf itself". `smt::Proof` was already `(tag, key, value, siblings)`.

**Mutation checks**, run after the first run on a scratch copy, which is deleted:
- Checking unassigned statuses only on the commanded permit fails exactly the 5 `Invalid_State_Enum_Elsewhere` cases.
- Adding an owner-admission validity rule fails only `t1v1-boundary-empty-subjects`, on `effects.reject_reason` and `transcript_hash`.

## Register status

**Pass 3 entry 2 (unsorted lists)**: still decided, not in doubt.
- *Deciding text*: §6, "accepts the forms that INVALID_STATE rejects: unsorted listings". The new "The kernel processes the listing as read, taking commitment over the mapping it denotes" supports it.
- *Corpus*: agrees in all 16 cases.

**Pass 3 entry 12 (recorded fields the spec does not define)**: unchanged, a genuine gap that affects no value.
- The hand tier's `rejected`, `roots_unchanged`, `writes` and `keys_written` (12 values) and the expansion's `coverage` tally all agree, compared informationally.
- What counts as a read is declared OPEN by the spec (protocol.md §2, Q19).

**Pass 2 NA2 (a committed leaf that no proof can open)**: unchanged.
- *Declared OPEN by the spec*: how the complete state reaches the party re-running it. protocol.md §12 says "OPEN: chunk format", and the docket lists "checkpoint/snapshot chunk format".
- *By design, not a gap*: "Decoders and proofs refuse an unassigned discriminant", with "INVALID_STATE rejections are decided by re-running the transition against the complete input state, not by any proof".

**Pass 2 NA3 (whole-world validity against bounded access)**: unchanged, declared OPEN by the spec as Q19.
- *Text*: "INVALID_STATE's validity guard also scans this. Closing Q19 makes valid input a property canonical execution preserves".

**Pass 3 NA1 (the key-uniqueness clause routes nothing)**
- **(a) The redundant uniqueness clause**: resolved.
  - *Deciding text*: §7 now reads "State maps 32-byte keys to records. It is a finite mapping, not a sequence, so no key appears twice." The clause pass 5 quoted ("Every key is unique ... falls in the INVALID_STATE class") is gone.
  - *Why it resolves*: uniqueness is now a consequence of what state is, not a condition that routes to INVALID_STATE.
  - *Wording residue, no effect*: protocol.md §1 still has "Keys are unique; ... Any violation of these constraints renders the state malformed". §7's specific rules route both kinds of repeat, so nothing is left undecided.
- **(b) What a refusal returns**: resolved.
  - *Deciding text*: "Because refusal occurs before any transition, it produces no outcome, commitment, or transcript."
  - *Implemented by*: change 1.
- **(c) Counting entries or keys for "the blockmon count equals created"**: changed, still a genuine gap, and harmless.
  - *The tension*: "The kernel processes the listing as read" now leans toward counting entries. "Repeated keys with identical records map to a single entry" leans toward the mapping.
  - *Why it is unobservable*: wherever the two counts differ there is an identical repeat, so canonical form fails and the outcome is INVALID_STATE either way.
  - *Implementation*: my kernel counts listing entries, unchanged.
  - *Corpus, declared*: the coverage scan showed that all 6 `Repeated_Blockmon` inputs set `created` to the mapping's key count. This decides nothing.

**Pass 4 NA1 and NA2**: still resolved, by the same text pass 5 quoted: "The §6 state reader is the sole exception" and "Malformed takes precedence".

**Pass 4 NA3 remainder (does the producer hold records or only commitments)**: resolved.
- *Deciding text*: protocol.md §2, "The kernel stores the actual records in the materialised world next to it."
- *Why it resolves*: this matches §7's "A producer with the domain state". My `WorldStore` already keeps records beside each tree.
- I cannot tell whether the sentence is new.

**Pass 5 NA1 (bytes that are not a listing)**: resolved, in favour of pass 5's reading.
- *Deciding text*: "The state reader enforces §2's structural rules, rejecting input that is not a listing, such as truncation or trailing bytes."

**Pass 5 NA2 (what the kernel receives)**: resolved, in favour of pass 5's reading.
- *Deciding text*: "The kernel processes the listing as read, taking commitment over the mapping it denotes."

**Entries resolved in earlier passes, rechecked**: entries 3 to 8, 10 and 11 are still decided by text present in the amended documents. Entry 10 is now also exercised (see Coverage observations).

## New ambiguities

1. **A refused update within a multi-update write set.**
   - *What the text settles*: §7 says "A rejected update leaves the domain root at its pre-state value" and "A batch groups updates to distinct keys within a single domain".
   - *The gap*: no text says whether refusing one update voids the rest of its batch, or the transition's updates in other domains.
   - *Status*: protocol.md §2 makes atomic publication a condition of closing Q19 ("closing Q19 also requires batch semantics that publish new domain roots atomically"). So the underlying item is declared OPEN by the spec.
   - *My reading*:
     - Each update stands alone. `advance` and `verify_updates` stop at the first refused update, which leaves its own domain root unchanged (the new test).
     - Updates applied earlier in the list stay applied.
     - The checker discards the store on any refusal, so it never reports a partially moved commitment.
   - *Effect*: not reachable in Transition 1. The kernel's writes are always admitted (asserted on every executed transition), and it writes at most one key per domain.

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents. The refusal path adds only §6's statements about the reader.

The exceptions are not protocol semantics:
- **Test-only items**: the hash counter, the domain `blockmon/test/v0` and the fixture values.
- **Corpus format**:
  - the JSON representation: `0x` hex, decimal strings for `u64` and `u32`, integer enums, `null` for absence, and the field names;
  - the `tag:0x<key>` labels and root-field names in the informational comparisons;
  - the shape of the `coverage` object;
  - **new this pass**: treating an absent or `null` recorded output as agreeing with a refusal's "none". No case exercises it.

## Coverage observations

These are judged from the inputs alone (`g0c-v1/coverage-scan-pass6.txt`).

**New this pass.** 21 cases were added, closing four of the gaps pass 5 listed:
- **An unassigned discriminant on another permit**: 5 `Enum_Elsewhere` cases, all status 0 on a non-commanded permit. Each would otherwise execute.
- **Identical repeats**: 6 in `blockmon` and 8 in `permits`. One of the permit cases repeats the commanded permit.
- **An empty subject domain**: 1 case. It holds 3 blockmon records whose owners are therefore not admitted, so it pins "Its `owner` need not be an admitted subject" (confirmed by mutation).
- **An empty permit domain**: 1 case.

**Still pinned**
- Every adjacent precondition pair that can fail together. UNKNOWN_PERMIT and PERMIT_NOT_RESERVED cannot.
- The strict roll threshold: one executed case has the roll equal to the rate, and one has it one below.
- One `assigned_round` overflow.
- 18 executed cases with `catch_rate_bp` above 10000.
- CREATURE_EXISTS in 8 cases.
- Unsorted listings: 6 subjects, 4 blockmon, 6 permits.
- Unassigned values on the commanded permit: 16 statuses and 8 `encounter_class` values.

**Not exercised**
- Both reader refusals:
  - conflicting records, which by §6 leave nothing to record;
  - structural refusals, which JSON cannot express.
- A non-zero unassigned status, or any unassigned `encounter_class`, on a non-commanded permit. A kernel that rejected only status 0 on other permits would pass.
- The entries-or-keys count reading, which is unobservable by construction.
- Proofs, authenticated updates, deletions, Malformed precedence, the producer and verifier cost split, and refused updates in a write set: none is recorded.
- Sequences and re-runs: every case is a single transition.
- A `creature_id` derived from its own origin permit: 0 of 546 records.
- Long shared key prefixes: at most 11 bits in the expansion and 1 bit in the hand tier.
- **Hand tier**: three checks, all with an empty blockmon domain.

**Possible regeneration of earlier cases, unconfirmed.** Over the 323 pre-existing case names, three of my balance figures differ from what passes 3 to 5 recorded:
- **Blockmon records**: 504, where they recorded 501.
- **Empty blockmon domain**: 77 cases, 38 of them executed, where they recorded 80 and 40.
- **Executed last-capability cases**: 36, where they recorded 34.

Other figures match: 132 executed, 27 with `round_period` 1, 37 with margin 0 and 37 with a rate of 10000 or more. I cannot tell whether a few earlier cases were regenerated or the earlier scans counted differently, because their scripts are not in STAGING. Every value agrees either way.

---

# G0c cleanroom report, pass 7: Transition 1 under `blockmon/world/v1`

Verbatim report of the seventh isolated session, 2026-10-19. Inputs: the two specification documents trimmed after the sixth pass, the two Transition 1 v1 tiers, the sixth-pass crate, and the six earlier reports. No other inputs were provided. The report declares the commit subjects, git status, and memory notes in its context, plus one small slip outside its directory that read nothing. The report is returned as the final message, copied here unchanged.

## RESULT

**PASS.** The amended text changes no computed value. Every recorded value in both corpora is reproduced, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational compared | Informational disagreements |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 12 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 344 | 8601 | 0 | 0 | 1 (the `coverage` tally) | 0 |

- **Transitions**: invariants were asserted on all 347 computed transitions. The hand tier gave 1 created, 1 roll failed and 1 rejected. The expansion gave 82 created, 50 roll failed and 212 rejected. The state reader refused no case.
- **Quality gate**, run from `impl/`:
  - `cargo fmt --check` passes.
  - `cargo clippy --quiet --all-targets --all-features` passes.
  - `cargo test --release --quiet`: 63 passed, 0 failed.
- **Runs**: the first run of the updated checker passed (`g0c-v1/first-run-pass7.txt`). The final run (`g0c-v1/final-run-pass7.txt`) is byte-identical to it.

## Files read

All paths are under STAGING. My first command changed into STAGING.

- `spec/canonical-encoding.md` and `spec/protocol.md`, in full.
- `g0c-v1/REPORT-pass6.md`, in full.
- `REPORT-pass1.md` to `REPORT-pass5.md`, only through my scripts (`quote_diff.py`, `sentence_scan.py`) and `grep` for specific phrases. I did not read them end to end.
- `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `.gitignore` and all eight files in `src/`, in full. `Cargo.lock` was listed but not opened.
- Both vector files, by script only: the top-level keys and metadata (`tier`, `commitment_version`, `derivation`, `scenario_source`, `provenance`, `seed`), the field names of cases, and the case-name families with their counts. I never viewed a recorded output value or the `coverage` tally.

**Exposure declared.** None of the following decided anything.
- **Harness context**: the harness attached the repository's git status and recent commit subjects to my context.
  - The status shows modified `docs/architecture/canonical-encoding.md` and `docs/architecture/prototype-and-technology.md`, a modified `.odin`, and an untracked `test.odin`.
  - The subjects are:
    - "docs(architecture): illustrate flows and drop change narration"
    - "build: Python on a uv environment, and lint for Solidity, workflows and docs"
    - "test(conformance): mutation harness, and cross-target over the Transition 1 corpus"
    - "feat(conformance): G0c-v1 cleanroom for Transition 1 under world/v1"
    - "docs(conformance): clarify that a tree proof's leaf is not part of the proof"
  - The first subject hints that §7's mermaid diagram is new. The diagram adds no semantics, and I checked it against the field list.
- **Memory notes**: two user memory notes mention a prose-rewrite skill and blockmon's Rust lint conventions.
- **Slip**: the harness saved one long `cat` of `smt.rs` to its own tool-results file outside STAGING. I did not open that file; I read `smt.rs` in STAGING instead.

**Files I wrote**
- Edits to `impl/src/invariants.rs` and `impl/src/smt.rs`.
- `g0c-v1/quote_diff.py` and `g0c-v1/sentence_scan.py`.
- `g0c-v1/first-run-pass7.txt` and `g0c-v1/final-run-pass7.txt`.
- `g0c-v1/mutant/`, a temporary copy of the crate for one mutation check, since deleted.

## Changes from the sixth pass

All changes were made before the first run. None alters a computed protocol value, and the first run prompted no change.

1. **New invariant on every executed transition: the kernel's writes give the same result in every order** (`invariants.rs`, `check_declared_writes` plus a `permutations` helper).
   - *Text*: §7, "The resulting domain root is order-independent because every permutation yields the same leaf set ... Anchoring remains invariant under permutation for the same reason: since no other update in the batch targets a specific key, that key's old value is identical regardless of position."
   - *Change*: the declared writes are applied in all orderings, both as the producer applies them (`advance`) and as anchored updates a verifier checks (`verify_updates`). Each must anchor and land on the full derivation of the post-state.
   - *Mutation check*, run after the first run on a scratch copy that is now deleted: making `verify_updates` refuse any batch that starts with the supply key fails exactly the 134 executed transitions. Only the new invariant fires.
2. **`smt.rs` batch test**: `batch_root_is_order_independent` now covers all six orders of three insertions. *Text*: the same §7 paragraph.
3. **New `smt.rs` test**: `same_key_updates_compose_sequentially_to_their_final_value`.
   - *Text*: §7, "Updates to the same key do not form a batch; they compose sequentially and must be normalised to a single final value before this property applies."
   - *What it checks*: absent to a to b to c equals absent to c. A second update whose old value skips the intermediate one is refused as `OldValueDoesNotAnchor`.
4. **New `invariants.rs` test**: `permutations_are_complete_and_distinct`. Tests went from 61 to 63.

**Needed no change**:
- §6's reworded reader paragraph and the kernel taking the listing as read: `world::read_state` already does this.
- §7's domain-state rules: in `WorldV0` each key comes from the record itself, and supply sits at the zero key.
- §7's "Each level holds its own empty commitment ... an assumption rather than a validation condition": nothing in the crate validates it.
- The unit subject "would prepend four zero bytes" if treated as a `bytes` field: `subject_leaf_preimage_ends_at_the_key` already covers it.

## Register status

**Pass 3 entry 2 (unsorted listings)**: still decided. The corpus agrees.
- *Deciding text*: §6, "the reader accepts forms that INVALID_STATE rejects: unsorted listings, identical repeated keys, and unassigned enum discriminants", and "The kernel processes the listing as read and commits to the mapping it denotes."

**Pass 3 entry 12 (recorded fields the spec does not define)**: unchanged. It is a genuine gap that affects no value.
- The 12 hand-tier values and the expansion's `coverage` tally agree informationally.
- What counts as a read is part of Q19, which the spec declares OPEN: "OPEN (register Q19): this bound constrains execution, not just hashing."

**Pass 2 NA2 (a committed leaf that no proof can open)**: unchanged.
- *Declared OPEN by the spec*: how the complete state reaches the party re-running it. protocol.md §12 says "OPEN: chunk format".
- *By design, not a gap*: "Decoders and proofs refuse an unassigned discriminant, and Transition 1 rejects state that holds one; the commitment does not." Also "INVALID_STATE rejections are decided by re-running the transition against the complete input state, not by any proof."

**Pass 2 NA3 (whole-world validity against bounded access)**: reworded, still declared OPEN by the spec as Q19.
- *Text*: "Precondition reads and the INVALID_STATE validity guard still scan the materialised world. Closing Q19 requires valid input to be a property preserved by canonical execution, checked only at genesis and snapshot import".

**Pass 3 NA1(c) (count list entries or mapping keys for "the blockmon count equals created")**: reworded, still a genuine gap, and harmless.
- *The tension*: §7 now says "An identical repeated key denotes the mapping without the repeat, but its listing is non-canonical, so Transition 1 rejects it as INVALID_STATE", which leans towards counting keys. §6, "The kernel processes the listing as read", leans towards counting entries.
- *Why it is unobservable*: the two counts differ only when a key is repeated, which is INVALID_STATE either way.
- *Implementation*: my kernel counts list entries, unchanged.

**Pass 3 NA1(a) and (b)**: still resolved. (b) is reworded: "This refusal occurs before any transition, so it produces no outcome, commitment, or transcript."

**Pass 4 NA1 and NA2**: still resolved, by "The §6 state reader is the sole exception; it reads Transition 1 kernel input" and "Malformed takes precedence."

**Pass 4 NA3 remainder (does the producer hold records or only commitments)**: changed, and still resolved, but now by inference.
- *What changed*: pass 6's deciding sentence, "The kernel stores the actual records in the materialised world next to it", is gone.
- *What decides it now*: "Precondition reads and the INVALID_STATE validity guard still scan the materialised world". That guard checks enum values and supply arithmetic, which needs the records. §7's "A producer with the domain state" supports the same reading. `WorldStore` is unchanged.

**Pass 5 NA1 (bytes that are not a listing)**: changed, and still resolved.
- *Deciding text*: "While maintaining §2's structural rules against truncation or trailing bytes".
- *Residue*: "This refusal occurs before any transition" now follows only "It rejects listings that denote no mapping". So what a structural refusal yields is no longer stated outright. It follows from the reader running before the kernel, and JSON cannot express such input.

**Pass 5 NA2 (what the kernel receives)**: still resolved. *Deciding text*: "The kernel processes the listing as read and commits to the mapping it denotes."

**Pass 6 new ambiguity 1 (a refused update within a multi-update write set)**: still open, and declared OPEN by the spec.
- *What the new text settles*: the new batch paragraph settles order independence (changes 1 to 3).
- *What it leaves open*: whether refusing one update voids the rest of the batch, or the transition's updates in other domains. Q19 still lists "batch semantics that publish new domain roots atomically" as a closing condition.
- *Implementation*: my reading and code are unchanged. Updates stop at the first refusal, and the checker discards the store.

**Entries resolved in earlier passes, rechecked**: entries 3 to 8, 10 and 11 are still decided by text present in the amended documents.

## New ambiguities

1. **The claimed pre-state root of each update inside a batch.**
   - *The gap*: §7 defines an update against "the claimed pre-state domain root", and says a batch's anchoring is order-invariant because each key's old value is unchanged by position. It does not say which root, or whose siblings, the second and later updates in a batch anchor in: the batch's pre-state, or the root the previous update left.
   - *My reading*: each update anchors in the root its predecessor left, with siblings from the current tree. `verify_updates` already does this.
   - For updates to one key, the normalised update takes the first old value and the last new value.
   - *Effect*: not reachable in Transition 1, which writes at most one key per domain.
2. **"refused, not climbed".**
   - *The conflict*: §7 says "An old value not committed by the claimed pre-state root is refused, not climbed." Yet deciding that the old value is uncommitted requires climbing it ("The verifier computes the old level-0 value, climbs the siblings, and requires the result to equal the claimed pre-state domain root").
   - *My reading*: the new value is not climbed, and no post-state root exists. `apply_update` and `advance` already behave this way.
   - *Effect*: none on any value.

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents. The new invariant and tests use only §7's batch paragraph.

The exceptions are not protocol semantics:
- **Test-only items**: the hash counter, the domain `blockmon/test/v0` and the fixture values.
- **Corpus format**:
  - the JSON representation: `0x` hex, decimal strings for `u64` and `u32`, integer enums, `null` for absence, and the field names;
  - the `tag:0x<key>` labels and root-field names in the informational comparisons;
  - the shape of the `coverage` object;
  - treating an absent or `null` recorded output as agreeing with a refusal's "none".

## Coverage observations

I did not repeat pass 6's input scan. The case families and counts I printed match pass 6 exactly, and the brief states both corpora are unchanged, so pass 6's coverage findings carry over. In particular, these are still not exercised:
- either reader refusal;
- a non-zero unassigned status, or any unassigned `encounter_class`, on a non-commanded permit;
- proofs, authenticated updates, deletions and Malformed precedence;
- sequences and re-runs;
- a `creature_id` derived from its own origin permit;
- long shared key prefixes.

The newly asserted batch rule is reached only by the kernel's writes: two or three keys, at most one per domain, on 134 executed transitions. These are not reached by any input:
- a batch of several keys in one domain;
- updates to the same key composing in sequence;
- a refusal inside a batch;
- the per-update pre-state root question (new ambiguity 1).

They are covered only by unit tests.

---

# G0c cleanroom report, pass 8: Transition 1 under `blockmon/world/v1`

Verbatim report of the eighth isolated session, 2026-10-19. Inputs: the two specification documents (amended after the seventh pass), the two Transition 1 v1 tiers, the seventh-pass crate, and the seven earlier reports. No other inputs were provided. The report declares the git status, commit subjects, and memory notes within its context, plus one small slip outside its directory that read nothing. The report was returned as the final message and is copied here unchanged.

## RESULT

**PASS.** The amended text changes no computed value. Every recorded value in both corpora is reproduced, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational compared | Informational disagreements |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 12 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 344 | 8601 | 0 | 0 | 1 (the `coverage` tally) | 0 |

- **Transitions**: invariants were asserted on all 347 computed transitions.
  - Hand tier: 1 created, 1 roll failed, 1 rejected.
  - Expansion: 82 created, 50 roll failed, 212 rejected.
  - The state reader refused no case.
- **Quality gate**, run from `impl/`: `cargo fmt --check` passes, `cargo clippy --quiet --all-targets --all-features` passes, and `cargo test --release --quiet` gives 65 passed, 0 failed.
- **Runs**: the first run of the updated checker passed (`g0c-v1/first-run-pass8.txt`). The final run (`g0c-v1/final-run-pass8.txt`) is byte-identical to it.

## Files read

All paths are under STAGING. My first command changed into STAGING.

- **Specs**: `spec/canonical-encoding.md` and `spec/protocol.md`, in full.
- **Reports**:
  - `g0c-v1/REPORT-pass7.md`, in full.
  - `REPORT-pass5.md` and `REPORT-pass6.md`, only through my script `g0c-v1/quote_check.py`.
  - `REPORT-pass1.md` to `REPORT-pass7.md`, through `grep` for specific phrases. I did not read pass 1 to 6 end to end.
- **Crate**: `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `.gitignore` and all eight files in `src/`, in full. I did not open `Cargo.lock`.
- **Vectors**, by script only: the top-level keys of both files, and the type and length of the expansion's `records` key (a 213-character string, which pass 6 also listed). I viewed no recorded output value and not the `coverage` tally.

**Exposure declared.** None of it decided anything.
- **Harness context**:
  - The git status shows modified `docs/architecture/canonical-encoding.md` and `docs/architecture/protocol.md`, a modified `.odin`, and an untracked `test.odin`.
  - The recent commit subjects match the five listed in pass 7.
- **Memory notes**: two user notes about a prose-rewrite skill and blockmon's Rust lint conventions.
- **Slip**: the harness saved one long `cat` of `smt.rs` to a tool-results file outside STAGING. I did not open it; I read `smt.rs` in STAGING instead.
- **Missing scripts**: pass 7's `quote_diff.py` and `sentence_scan.py` are not in STAGING. I wrote `g0c-v1/quote_check.py`, which lists every sentence quoted in an earlier report that no longer appears verbatim in the spec. I used it only to find edited text, never to decide semantics.

**Files I wrote**: edits to `impl/src/world.rs` and `impl/src/smt.rs`, plus `g0c-v1/quote_check.py`, `g0c-v1/first-run-pass8.txt` and `g0c-v1/final-run-pass8.txt`.

## Changes from the seventh pass

I made all of these before the first run. None alters a computed protocol value, and the first run prompted no change.

1. **`WorldStore` holds leaf commitments, not records** (`world.rs`).
   - *Text*: protocol.md §2, "The store holds leaf commitments, not records. The kernel keeps records in the materialised world, and its precondition reads plus the INVALID_STATE validity guard scan that world."
   - *What changed*: the per-domain `Domain { records, tree }` is gone. Each domain is now a plain `Store`.
   - *Effect on `advance`*: it can no longer compare a write's old value with a held record. Instead it requires the old value's level-0 commitment to equal the store's level-0 slot (new `Store::level_zero`); otherwise it refuses with `OldValueDoesNotAnchor`.
   - *Cost*: this spends one extra leaf hash per write whose old value is a record. §7 permits it: "That is the producer's minimum. Implementations may additionally ... spend further depth-bounded work maintaining their representation."
   - *Test*: `moving_the_commitment_costs_the_same_at_any_population` now expects `3 * (1 + DEPTH) + 2 + 1` producer hashes, which is still the same at both populations.
2. **`smt::admitted_level_zero` returns `(old, new)` level-0 commitments.**
   - It checks both records for malformedness before hashing either, so "Malformed takes precedence" holds unchanged.
   - Its test now expects a cost of 2 hashes.
3. **New test `each_batch_update_anchors_in_the_root_its_predecessor_left`**.
   - *Text*: §7, "Batch updates apply in sequence. The first anchors in the batch's pre-state root. Each subsequent update anchors in the root produced by its predecessor, taking siblings from the tree as the earlier updates left it."
   - *What it checks*: the second insertion in one domain lands on the full derivation with fresh siblings. With pre-state siblings it is refused against the predecessor's root. Anchored in the batch's pre-state root, it does not reach the batch result.
4. **New test `a_refused_update_climbs_only_its_old_value`**.
   - *Text*: §7, "When the old value's climb fails to reach the claimed pre-state root, the update is refused and the new value is not climbed."
   - *What it checks*: a refused update costs exactly two leaf hashes and one climb (`2 + DEPTH`).

Tests went from 63 to 65.

**Needed no change**:
- **§6 reader paragraph**: it now reads "including unsorted listings ...", "It refuses inputs that break §2's structural rules, such as truncation or trailing bytes, and listings that denote no mapping. Both refusals occur before any transition". `world::read_state` and the corpus refusal path already do exactly this.
- **`verify_updates`** already anchors each update in its predecessor's root, with siblings from the current tree.
- **`apply_update`** already climbs the new value only after the old value anchors.

## Register status

**Pass 7 new ambiguity 1 (the pre-state root of each update within a batch)**: resolved, and my reading is confirmed.
- *Deciding text*: §7, "Batch updates apply in sequence. The first anchors in the batch's pre-state root. Each subsequent update anchors in the root produced by its predecessor, taking siblings from the tree as the earlier updates left it."

**Pass 7 new ambiguity 2 ("refused, not climbed")**: resolved, and my reading is confirmed.
- *Deciding text*: §7, "When the old value's climb fails to reach the claimed pre-state root, the update is refused and the new value is not climbed." The old sentence is gone.

**Pass 4 NA3 remainder (does the producer hold records or only commitments)**: resolved, now by explicit text rather than inference, but in a direction that required change 1.
- *Deciding text*: protocol.md §2, "The store holds leaf commitments, not records. The kernel keeps records in the materialised world".

**Pass 5 NA1 residue (what a structural refusal yields)**: resolved.
- *Deciding text*: §6, "It refuses inputs that break §2's structural rules, such as truncation or trailing bytes, and listings that denote no mapping. Both refusals occur before any transition, so they have no outcome, commitment, or transcript."

**Pass 6 new ambiguity 1 (a refused update within a multi-update write set)**: changed, and still declared OPEN by the spec.
- *The tension*: read with "A rejected update leaves the domain root at its pre-state value", the new sequencing text makes a mid-batch refusal leave the root its predecessor produced, which is non-atomic. Q19 still lists "batch semantics that publish new domain roots atomically" as a closing condition.
- *Implementation*: unchanged. Updates stop at the first refusal, and the checker discards the store.
- *Effect*: unreachable, since Transition 1 writes at most one key per domain.

**Pass 2 NA3 (whole-world validity against bounded access)**: reworded, still declared OPEN as Q19.
- *Text*: "its precondition reads plus the INVALID_STATE validity guard scan that world. Closing Q19 requires valid input to be a property preserved by canonical execution, checked only at genesis and snapshot import".

**Pass 2 NA2 (a committed leaf that no proof can open)**: unchanged.
- *Declared OPEN by the spec*: how complete state reaches the re-runner, under protocol.md §12, "OPEN: chunk format".
- *By design, not a gap*: "Decoders and proofs refuse an unassigned discriminant, and Transition 1 rejects state that holds one; the commitment does not."

**Pass 3 entry 12 (recorded fields the spec does not define)**: unchanged. It is a genuine gap that affects no value, and the read-set part sits under Q19, which the spec declares OPEN. All 13 informational values agree.

**Pass 3 NA1(c) (count list entries or mapping keys for the blockmon count)**: unchanged, a genuine but unobservable gap.
- *Why it remains*: §7's "its listing is non-canonical, so Transition 1 rejects it as INVALID_STATE" and §6's "The kernel processes the listing as read" are both still present.
- *Why it is unobservable*: the two counts differ only when a key repeats, and that is INVALID_STATE either way.

**Pass 3 entry 2, Pass 3 NA1(a) and (b), Pass 4 NA1 and NA2, Pass 5 NA2, and entries 3 to 8, 10 and 11**: still decided by text present in the amended documents.
- §6 now reads "accepts forms that INVALID_STATE rejects, including unsorted listings, identical repeated keys, and unassigned enum discriminants".
- §6 still says "The kernel processes the listing as read and commits to the mapping it denotes".
- §7 now reads "Malformed takes precedence. Because shape and admissibility are checked before the anchoring climb, an update that is both malformed and unanchored is rejected as Malformed".

## New ambiguities

1. **Whether the producer must check a write's old value, and against what.**
   - *The gap*: §7 says the producer "already knows the pre-state root and climbs once. That is the producer's minimum." That minimum includes no old-value check. With records now outside the store, a producer that does check must either hash the old record against the store's level-0 slot (my reading) or consult the materialised world.
   - *Why it does not matter here*: both readings are permitted as "further depth-bounded work", and neither changes any value.
2. **"including" and "such as" make the reader's lists illustrative.**
   - *The question*: the general rules are "accepts forms that INVALID_STATE rejects" and "refuses inputs that break §2's structural rules". §2 also lists unassigned discriminants among its rules, and only the illustrative list places them on the accepted side.
   - *Effect*: none for `WorldV0`, whose only §2-checkable forms are truncation, an oversized count, trailing bytes and enum discriminants.

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents. The new code and tests use only protocol.md §2's store sentence and §7's batch-sequencing and refusal sentences.

The exceptions are not protocol semantics, and they are unchanged from pass 7:
- **Test-only items**: the hash counter, the domain `blockmon/test/v0` and the fixture values.
- **Corpus format**: the JSON representation (`0x` hex, decimal strings, integer enums, `null`), the field names, the `tag:0x<key>` labels, the shape of `coverage`, and treating an absent or `null` recorded output as agreeing with a refusal.

## Coverage observations

Both corpora are unchanged: same top-level keys and case count, and identical results under the new code. Pass 6's input scan therefore still holds. These are still not exercised by any input:
- either state-reader refusal;
- a non-zero unassigned status, or any unassigned `encounter_class`, on a non-commanded permit;
- proofs, authenticated updates, deletions and Malformed precedence;
- sequences and re-runs;
- a `creature_id` derived from its own origin permit;
- long shared key prefixes.

The newly decided batch rules are not reachable from Transition 1 inputs, and are covered only by unit tests:
- several updates in one domain anchoring in sequence;
- a refused update's single climb;
- a refusal mid-batch.

Transition 1 writes at most one key per domain (two or three keys on each of 134 executed transitions).

---

# G0c cleanroom report, pass 9: Transition 1 under `blockmon/world/v1`

Verbatim report of the ninth isolated session, 2026-10-19. Inputs: the two specification documents (as amended after the eighth pass), the two Transition 1 v1 tiers, the eighth-pass crate, and the eight earlier reports. Nothing else was provided. The report declares the git status, commit subjects, memory notes and global instructions in its context. It returned the report as its final message, copied here unchanged.

## RESULT

**PASS.** The amended text changes no computed value. Both corpora reproduce in full, no invariant is violated, and the quality gate passes.

| Corpus | Checks | Values compared | Mismatches | Invariant violations | Informational compared | Informational disagreements |
|---|---|---|---|---|---|---|
| `vectors/g0a-t1-v1.json` | 3 | 82 | 0 | 0 | 12 | 0 |
| `vectors/g0a-t1-v1-expansion.json` | 344 | 8601 | 0 | 0 | 1 (the `coverage` tally) | 0 |

- **Transitions**: invariants were asserted on all 347 computed transitions.
  - Hand tier: 1 created, 1 roll failed, 1 rejected.
  - Expansion: 82 created, 50 roll failed, 212 rejected.
  - The state reader refused no case.
- **Quality gate**, run from `impl/`:
  - `cargo fmt --check` passes.
  - `cargo clippy --quiet --all-targets --all-features` passes.
  - `cargo test --release --quiet`: 65 passed, 0 failed.
- **Runs**: the first run is in `g0c-v1/first-run-pass9.txt` and passed. The final run is in `g0c-v1/final-run-pass9.txt`. Leaving out cargo's build lines, the two are identical.

## Files read

All paths are under STAGING. My first command changed into STAGING.

- **Specs**: `spec/canonical-encoding.md` and `spec/protocol.md`, in full.
- **Reports**:
  - `g0c-v1/REPORT-pass8.md`, in full.
  - `REPORT-pass1.md` to `REPORT-pass8.md`, only through my script `g0c-v1/quote_check.py` and through `grep` for specific phrases. I did not read pass 1 to 7 end to end.
- **Crate**:
  - In full: `g0c-v1/impl/Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `.gitignore`, and `src/main.rs`, `world.rs`, `t1.rs`, `encoding.rs`, `kernel.rs` and `invariants.rs`.
  - In part: `src/smt.rs` lines 1 to 420, which is all the non-test code, and `src/corpus.rs` lines 1 to 400.
  - Not opened: `Cargo.lock`.
- **Vectors**: not opened directly. The checker read them, and I looked only at its summary output.

**Exposure declared.** None of it decided anything.
- **Harness context**: the git status listed modified `docs/architecture/canonical-encoding.md` and `docs/architecture/protocol.md`, a modified `.odin`, an untracked `test.odin`, and five recent commit subjects. These are the same five subjects that pass 7 lists.
- **Notes outside STAGING**: two user memory notes, one about a prose-rewrite skill and one about blockmon's Rust lint conventions, plus the user's global instructions.
- **Missing script**: pass 8's `quote_check.py` was not in STAGING, so I rewrote it.
  - It lists every sentence quoted in an earlier report that no longer appears verbatim in the spec. I used it only to locate edited text.
  - **Limit**: it cannot detect new text that no earlier report quoted. Because of that, I also re-read both documents in full against the code.

**Files I wrote**: edits to `impl/src/world.rs`, plus `g0c-v1/quote_check.py`, `g0c-v1/first-run-pass9.txt` and `g0c-v1/final-run-pass9.txt`.

## Changes from the eighth pass

The only edited text I found is §6's state-reader paragraph. Pass 8 quoted it as "accepts forms that INVALID_STATE rejects, including unsorted listings, ..." and "It refuses inputs that break §2's structural rules, such as truncation or trailing bytes, and listings that denote no mapping". It now reads:

> "It accepts three forms that INVALID_STATE rejects: unsorted listings, identical repeated keys and unassigned enum discriminants. It refuses input that fails to frame as a listing under §2 (truncation, count exceeding remaining input, or trailing bytes) and listings that denote no mapping."

`world::read_state` already behaves exactly this way. The strict-or-lenient decoder keeps any discriminant, and §2's sequence-length check gives `LengthExceedsInput`. So no behaviour changed. I made one change, before the first run, which touches no computed value:

1. **`world.rs`**:
   - *Doc comment*: the comment on `read_state` now states that both lists are exhaustive.
   - *Test*: the existing test `the_state_reader_keeps_what_invalid_state_rejects` gained an assertion. A `subjects` count of `u32::MAX` is now refused as `ReadError::Structure(DecodeError::LengthExceedsInput)`. Until now, only truncation and trailing bytes had a test.
   - *Test count*: unchanged at 65, because the assertion went into an existing test.

The first run prompted no change.

## Register status

**Pass 8 new ambiguity 2 (the reader's lists were illustrative)**: resolved.
- *Deciding text*: "It accepts three forms that INVALID_STATE rejects: ..." and "fails to frame as a listing under §2 (truncation, count exceeding remaining input, or trailing bytes)".
- Both lists are now closed. Unassigned discriminants sit explicitly on the accepted side, and the refusal side names all three framing failures. My reading is confirmed, with no code change.

**Pass 8 new ambiguity 1 (whether, and against what, a producer checks a write's old value)**: unchanged, a genuine gap that affects no value.
- *Text still present*: §7, "That is the producer's minimum. Implementations may additionally anchor each update at the verifier's cost and spend further depth-bounded work maintaining their representation."
- My producer compares the old value's leaf with the store's level-0 slot. That costs one leaf hash, which is below the verifier's cost, and I justify it as "further depth-bounded work". The text still does not say whether a producer must check at all.

**Pass 6 new ambiguity 1 (a refused update within a multi-update batch is non-atomic)**: unchanged, and declared OPEN by the spec.
- *The tension*: §7 still reads both "Batch updates apply in sequence ... Each subsequent update anchors in the root produced by its predecessor" and "A rejected update leaves the domain root at its pre-state value".
- *Why OPEN*: protocol.md §2 still lists, among Q19's closing conditions, "batch semantics that publish new domain roots atomically".
- *Effect*: unreachable in Transition 1, which writes at most one key per domain.

**Pass 2 NA3 (whole-world validity against bounded access)**: unchanged, declared OPEN as Q19.
- *Text*: "its precondition reads plus the INVALID_STATE validity guard scan that world. Closing Q19 requires valid input to be a property preserved by canonical execution, checked only at genesis and snapshot import".

**Pass 2 NA2 (a committed leaf no proof can open)**: unchanged.
- *Declared OPEN by the spec*: how complete state reaches the re-runner, under protocol.md §12, "OPEN: chunk format".
- *By design, not a gap*: "Decoders and proofs refuse an unassigned discriminant, and Transition 1 rejects state that holds one; the commitment does not", together with "INVALID_STATE rejections are decided by re-running the transition against the complete input state, not by any proof."

**Pass 3 entry 12 (recorded fields the spec does not define)**: unchanged.
- *Genuine gap, no value affected*: the corpus fields `derivation`, `scenario_source`, `tier`, `provenance`, `records` and `seed` have no meaning in the spec.
- *Declared OPEN by the spec*: the read-set part sits under Q19.

**Pass 3 NA1(c) (count list entries or mapping keys for the blockmon count)**: unchanged, a genuine but unobservable gap.
- *Text*: "The kernel processes the listing as read" and "its listing is non-canonical, so Transition 1 rejects it as INVALID_STATE" are both still present.
- *Why unobservable*: the two counts differ only when a key repeats, and that is INVALID_STATE either way.

**All other earlier entries** remain decided by text still present verbatim. The script found no other quoted sentence missing. Examples:
- §1, "The §6 state reader is the sole exception".
- §7, "Malformed takes precedence".
- §6, "A `BlockmonRecord` has no validity rule beyond §7's identifier binding".
- §6, "`assigned_round` is computed exactly".
- §6, "A `catch_rate_bp` above 10000 is valid".

## New ambiguities

None. The amended paragraph closes a question without opening one.

## Divergences

None. Every recorded value in both corpora equals the computed value.

## Value sourcing

Every constant, discriminant, predicate, ordering and formula comes from the two spec documents. This pass's only addition is a test assertion that rests on the §6 reader sentence and §2's `seq` row ("count exceeding remaining input").

The exceptions are not protocol semantics and are unchanged from pass 8:
- **Test-only items**: the hash counter, the domain `blockmon/test/v0` and the fixture values.
- **Corpus format**: the JSON representation (`0x` hex, decimal strings, integer enums, `null`), the field names, the `tag:0x<key>` labels, the shape of `coverage`, and treating an absent or `null` recorded output as agreeing with a refusal.

## Coverage observations

Both corpora are unchanged, and the checker's results match pass 8's exactly. Pass 8's coverage list therefore still holds. No corpus input exercises:
- **State-reader refusals**: none of the three framing refusals, nor a conflicting repeated key. The newly enumerated "count exceeding remaining input" is covered only by a unit test.
- **Unassigned enums elsewhere**: a non-zero unassigned status, or any unassigned `encounter_class`, on a permit other than the commanded one.
- **Tree operations**: proofs, authenticated updates, deletions, and Malformed precedence, outside the kernel's own writes.
- **Multi-step scenarios**: sequences and re-runs.
- **Blockmon records**: a `creature_id` derived from its own origin permit.
- **Key shapes**: long shared key prefixes.
- **Batch rules** (sequential anchoring, a refused update's single climb, a mid-batch refusal): Transition 1 writes at most one key per domain, so only unit tests reach these.
