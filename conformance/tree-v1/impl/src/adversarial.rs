//! Step four: checks that the language this implementation accepts is no wider than the
//! spec permits. Each entry names the sentence it tests.

use crate::codec::DecodeError;
use crate::hash::{Hash32, SMT_EMPTY, SMT_LEAF, SMT_NODE, WORLD_V1, domain_is_well_formed};
use crate::proof::{Claim, Invalid, LogicalProof, Malformed, Rejection, recompute, verify};
use crate::record::{Record, Tag};
use crate::transition::{Cost, accepted, rejected};
use crate::tree::{DEPTH, DomainState, EmptyLadder, StateError, bit, climb, leaf_from_bytes};
use crate::world::WorldCommitmentV1;

pub struct Case {
    pub name: &'static str,
    pub authority: &'static str,
    pub held: bool,
    pub detail: String,
}

struct Cases(Vec<Case>);

impl Cases {
    fn add(&mut self, name: &'static str, authority: &'static str, held: bool, detail: String) {
        self.0.push(Case {
            name,
            authority,
            held,
            detail,
        });
    }
}

const fn key_with(byte0: u8) -> Hash32 {
    let mut key = [0u8; 32];
    key[0] = byte0;
    key
}

const fn declared_width(tag: Tag) -> usize {
    match tag {
        Tag::Subject => 0,
        Tag::Blockmon => 96,
        Tag::Encounter => 74,
        Tag::Supply => 40,
    }
}

/// A minimal record of the declared width whose identifier, if any, equals `key`.
fn bound_record(tag: Tag, key: &Hash32) -> Vec<u8> {
    let mut bytes = vec![0u8; declared_width(tag)];
    if matches!(tag, Tag::Blockmon | Tag::Encounter) {
        bytes[..32].copy_from_slice(key);
    }
    if matches!(tag, Tag::Encounter) {
        bytes[64] = 1;
        bytes[73] = 1;
    }
    bytes
}

const fn state_key(tag: Tag, byte0: u8) -> Hash32 {
    if matches!(tag, Tag::Supply) {
        [0u8; 32]
    } else {
        key_with(byte0)
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "a flat list of adversarial cases is easier to audit than a nest of helpers"
)]
pub fn run(ladder: &EmptyLadder) -> Vec<Case> {
    let mut cases = Cases(Vec::new());

    cases.add(
        "domain strings satisfy the CE §3 grammar",
        "CE §3: a domain is 1-255 bytes of printable ASCII, lowercase, ending in /v<decimal>",
        [SMT_LEAF, SMT_NODE, SMT_EMPTY, WORLD_V1]
            .iter()
            .all(|d| domain_is_well_formed(d)),
        "all four tree domains".to_owned(),
    );

    // Key ordering and uniqueness.
    let ordered: Vec<(Vec<u8>, Vec<u8>)> = [0x01u8, 0x02, 0x03]
        .iter()
        .map(|b| (key_with(*b).to_vec(), Vec::new()))
        .collect();
    let mut descending = ordered.clone();
    descending.reverse();
    let duplicated = vec![
        (key_with(1).to_vec(), Vec::new()),
        (key_with(1).to_vec(), Vec::new()),
    ];
    let equalish = vec![
        (key_with(2).to_vec(), Vec::new()),
        (key_with(2).to_vec(), Vec::new()),
        (key_with(3).to_vec(), Vec::new()),
    ];
    cases.add(
        "an ordered representation must be strictly ascending",
        "CE §7: where an ordered representation is required, keys appear strictly ascending \
         byte-lexicographically",
        DomainState::from_ordered(Tag::Subject, &descending).err()
            == Some(StateError::NotStrictlyAscending)
            && DomainState::from_ordered(Tag::Subject, &ordered).is_ok(),
        "descending rejected, ascending accepted".to_owned(),
    );
    cases.add(
        "repeated keys are rejected in both presentations",
        "CE §7 / PR §1: every key is unique",
        DomainState::from_ordered(Tag::Subject, &duplicated).is_err()
            && DomainState::from_mapping(Tag::Subject, &duplicated).err()
                == Some(StateError::DuplicateKey)
            && DomainState::from_mapping(Tag::Subject, &equalish).is_err(),
        "duplicate rejected as a mapping and as a sequence".to_owned(),
    );
    let by_map = DomainState::from_mapping(Tag::Subject, &descending)
        .map(|s| s.root(ladder))
        .expect("uniqueness holds");
    let by_order = DomainState::from_ordered(Tag::Subject, &ordered)
        .map(|s| s.root(ladder))
        .expect("strictly ascending");
    cases.add(
        "the root does not depend on presentation order",
        "CE §7: ordering is a property of representation, not state",
        by_map == by_order,
        format!("root {}", hex::encode(by_map)),
    );

    // Identifier binding.
    let mut unbound_blockmon = vec![0u8; 96];
    unbound_blockmon[0] = 0xaa;
    let mut unbound_permit = bound_record(Tag::Encounter, &key_with(0xaa));
    unbound_permit[0] = 0xbb;
    cases.add(
        "a record's own identifier must equal its tree key",
        "CE §7 / PR §1: where a record carries its own identifier, that identifier equals the \
         tree key",
        DomainState::empty(Tag::Blockmon)
            .insert(&key_with(1), &unbound_blockmon)
            .err()
            == Some(StateError::IdentifierMismatch)
            && DomainState::empty(Tag::Encounter)
                .insert(&key_with(0xaa), &unbound_permit)
                .err()
                == Some(StateError::IdentifierMismatch),
        "creature_id and permit_id both bound".to_owned(),
    );
    let unbound_proof = LogicalProof {
        tag: Tag::Blockmon.discriminant(),
        key: key_with(1).to_vec(),
        claim: Claim::Present(unbound_blockmon.clone()),
        siblings: vec![[0u8; 32]; DEPTH],
    };
    let unbound_rejected = matches!(
        recompute(&unbound_proof, ladder),
        Err(Rejection::Malformed(Malformed::IdentifierMismatch))
    );
    cases.add(
        "an unbound record identifier is malformed at the proof boundary",
        "CE §7 Proofs: malformedness covers domain-local record semantics, including a record \
         identifier that does not equal the proof key",
        unbound_rejected,
        "a proof whose creature_id differs from its key is rejected, not merely undesirable"
            .to_owned(),
    );

    // Domain-key admissibility.
    let supply_nonzero = DomainState::empty(Tag::Supply)
        .insert(&key_with(1), &bound_record(Tag::Supply, &[0u8; 32]))
        .err();
    let supply_proof = LogicalProof {
        tag: Tag::Supply.discriminant(),
        key: key_with(1).to_vec(),
        claim: Claim::Absent,
        siblings: vec![[0u8; 32]; DEPTH],
    };
    cases.add(
        "the supply domain admits exactly the zero key",
        "CE §7: 32 zero bytes, the only admissible key",
        supply_nonzero == Some(StateError::SupplyKeyNotZero)
            && recompute(&supply_proof, ladder).err()
                == Some(Rejection::Malformed(Malformed::SupplyKeyNotZero))
            && DomainState::empty(Tag::Supply)
                .insert(&[0u8; 32], &bound_record(Tag::Supply, &[0u8; 32]))
                .is_ok(),
        "rejected for state and for proofs, including absence proofs".to_owned(),
    );

    // Record widths, enum discriminants, tag validity.
    let mut widths_exact = true;
    let mut width_detail = Vec::new();
    for tag in Tag::ALL {
        let key = state_key(tag, 1);
        let exact = bound_record(tag, &key);
        let mut wide = exact.clone();
        wide.push(0);
        let narrow = exact
            .get(..exact.len().saturating_sub(1))
            .unwrap_or_default()
            .to_vec();
        let exact_ok = Record::decode(tag, &exact).is_ok_and(|r| r.tag() == tag);
        let wide_bad = Record::decode(tag, &wide) == Err(DecodeError::TrailingBytes { extra: 1 });
        let narrow_bad = exact.is_empty()
            || matches!(
                Record::decode(tag, &narrow),
                Err(DecodeError::Truncated { .. })
            );
        widths_exact &= exact_ok && wide_bad && narrow_bad;
        width_detail.push(format!("{}={}", tag.domain_name(), declared_width(tag)));
    }
    cases.add(
        "record widths are exact under strict exact-consume decoding",
        "CE §2: decoding a top-level value MUST consume the input exactly; trailing bytes MUST \
         be rejected",
        widths_exact,
        width_detail.join(" "),
    );

    let mut permit = bound_record(Tag::Encounter, &key_with(1));
    let mut enums_rejected = true;
    for bad in [0u8, 2, 3, 255] {
        permit[64] = bad;
        enums_rejected &= Record::decode(Tag::Encounter, &permit)
            == Err(DecodeError::UnassignedEnum {
                field: "encounter_class",
                discriminant: bad,
            });
    }
    permit[64] = 1;
    for bad in [0u8, 3, 4, 255] {
        permit[73] = bad;
        enums_rejected &= Record::decode(Tag::Encounter, &permit)
            == Err(DecodeError::UnassignedEnum {
                field: "status",
                discriminant: bad,
            });
    }
    cases.add(
        "unassigned enum discriminants are rejected, zero included",
        "CE §2 enum row and CE §6: enum zero is invalid on the wire throughout",
        enums_rejected,
        "encounter_class {1}, status {1,2}".to_owned(),
    );

    let mut tags_rejected = true;
    for candidate in 0u8..=255 {
        let assigned = matches!(candidate, 1..=4);
        let proof = LogicalProof {
            tag: candidate,
            key: [0u8; 32].to_vec(),
            claim: Claim::Absent,
            siblings: vec![[0u8; 32]; DEPTH],
        };
        let rejected_as_tag = recompute(&proof, ladder).err()
            == Some(Rejection::Malformed(Malformed::UnassignedTag {
                tag: candidate,
            }));
        tags_rejected &= assigned != rejected_as_tag;
    }
    cases.add(
        "exactly tags 1-4 are assigned; 0 and 5-255 are malformed",
        "CE §7: tags are assigned; 0 is not a valid tag",
        tags_rejected,
        "all 256 discriminants exercised".to_owned(),
    );

    // Proof shape.
    let key = key_with(0x11);
    let mut state = DomainState::empty(Tag::Blockmon);
    state
        .insert(&key, &bound_record(Tag::Blockmon, &key))
        .expect("bound record");
    let root = state.root(ladder);
    let good = LogicalProof {
        tag: Tag::Blockmon.discriminant(),
        key: key.to_vec(),
        claim: Claim::Present(bound_record(Tag::Blockmon, &key)),
        siblings: state.siblings(ladder, &key),
    };
    let mut shapes_rejected = true;
    for count in [0usize, 1, 128, 255, 257, 512] {
        let mut candidate = good.clone();
        candidate.siblings.resize(count, [0u8; 32]);
        shapes_rejected &= recompute(&candidate, ladder).err()
            == Some(Rejection::Malformed(Malformed::SiblingCount {
                actual: count,
            }));
    }
    for len in [0usize, 31, 33, 64] {
        let mut candidate = good.clone();
        candidate.key = vec![0u8; len];
        shapes_rejected &= recompute(&candidate, ladder).err()
            == Some(Rejection::Malformed(Malformed::KeyLength { actual: len }));
    }
    cases.add(
        "proof shape: 256 siblings and a 32-byte key, nothing else",
        "CE §7 Malformed: sibling count != 256; key length != 32",
        shapes_rejected,
        "sibling counts 0,1,128,255,257,512 and key lengths 0,31,33,64".to_owned(),
    );

    let mut world = WorldCommitmentV1::default();
    world.set_root_for(Tag::Blockmon, root);
    let mut mutated = good.clone();
    mutated.siblings[0] = [0xffu8; 32];
    let mut swapped = good.clone();
    swapped.siblings.swap(0, 1);
    cases.add(
        "the two rejection classes stay distinct",
        "CE §7: malformed and well-formed but invalid are distinct outcomes",
        verify(&good, &root, &world, ladder).is_ok()
            && verify(&mutated, &root, &world, ladder)
                == Err(Rejection::Invalid(Invalid::RootMismatch))
            && verify(&swapped, &root, &world, ladder)
                == Err(Rejection::Invalid(Invalid::RootMismatch))
            && verify(&good, &root, &WorldCommitmentV1::default(), ladder)
                == Err(Rejection::Invalid(Invalid::NotAtAssignedPosition)),
        "a tampered sibling is invalid, not malformed".to_owned(),
    );

    // Bit order, boundary positions.
    let mut bits_ok = true;
    for i in 0..DEPTH {
        let mut probe = [0u8; 32];
        probe[i / 8] = 0x80 >> (i % 8);
        bits_ok &= bit(&probe, i) == 1 && (0..DEPTH).filter(|j| bit(&probe, *j) == 1).count() == 1;
    }
    cases.add(
        "bit(i) is the (i mod 8)-th bit from the MSB of byte i / 8",
        "CE §7: bit position i mod 8 counted from zero at the most significant bit of byte i / 8",
        bits_ok,
        "all 256 single-bit keys isolate their own index".to_owned(),
    );

    let mut leftmost = DomainState::empty(Tag::Subject);
    leftmost.insert(&[0u8; 32], &[]).expect("unit");
    let mut rightmost = DomainState::empty(Tag::Subject);
    rightmost.insert(&[0xffu8; 32], &[]).expect("unit");
    let mut left_expected = leaf_from_bytes(1, &[0u8; 32], &[]);
    let mut right_expected = leaf_from_bytes(1, &[0xffu8; 32], &[]);
    for d in 0..DEPTH {
        left_expected = crate::tree::node(&left_expected, &ladder.at(d));
        right_expected = crate::tree::node(&ladder.at(d), &right_expected);
    }
    cases.add(
        "0 selects the left child and 1 the right, at every level",
        "CE §7: 0 selects the left child and 1 the right",
        leftmost.root(ladder) == left_expected && rightmost.root(ladder) == right_expected,
        "all-zero key hugs the left edge, all-ones key the right".to_owned(),
    );

    let absent = key_with(0x22);
    let absence = LogicalProof {
        tag: Tag::Blockmon.discriminant(),
        key: absent.to_vec(),
        claim: Claim::Absent,
        siblings: state.siblings(ladder, &absent),
    };
    cases.add(
        "an absent key's level-0 slot is empty[0] and needs no adjacency argument",
        "CE §7: the level-0 slot of an absent key holds empty[0]",
        verify(&absence, &root, &world, ladder).is_ok()
            && climb(&absent, ladder.at(0), &state.siblings(ladder, &absent)) == root,
        "fixed depth 256, no collapse".to_owned(),
    );

    let mut level_distinct = true;
    let mut seen = std::collections::BTreeSet::new();
    for level in 0..=DEPTH {
        level_distinct &= seen.insert(ladder.at(level));
    }
    cases.add(
        "each level holds its own empty commitment",
        "CE §7: each level holds its own empty commitment (an assumption, not a validation \
         condition)",
        level_distinct,
        "257 pairwise-distinct commitments, asserted but never enforced at runtime".to_owned(),
    );

    // Transition behaviour under CE §7 Cost.
    let mut input = WorldCommitmentV1::default();
    for tag in Tag::ALL {
        input.set_root_for(tag, DomainState::empty(tag).root(ladder));
    }
    let before = input.world_root();
    let untouched = rejected(&input, before);
    let touched = accepted(&input, &[(Tag::Blockmon, &state)], ladder);
    cases.add(
        "a rejected transition recomputes no world commitment",
        "CE §7 Cost: a rejected transition returns the input commitment unchanged and incurs no \
         state-recomputation hash",
        untouched.commitment == input
            && untouched.world_root == before
            && untouched.cost == Cost::default()
            && touched.cost
                == Cost {
                    leaf_hashes: 1,
                    node_hashes: DEPTH,
                    world_recomputations: 1,
                },
        "0 world recomputations rejected, 1 accepted".to_owned(),
    );

    let mut permuted = input;
    permuted.set_root_for(Tag::Blockmon, root);
    let mut misplaced = input;
    misplaced.set_root_for(Tag::Encounter, root);
    cases.add(
        "a domain root is bound by field position, not by tag arithmetic",
        "CE §7: the mapping uses the field name, not the tag's numeric value",
        permuted.world_root() != misplaced.world_root()
            && permuted.root_for(Tag::Blockmon) == root
            && misplaced.root_for(Tag::Blockmon) != root,
        "the same root at two positions gives two world roots".to_owned(),
    );

    let mut empty_domains_distinct = true;
    for tag in Tag::ALL {
        let state = DomainState::empty(tag);
        empty_domains_distinct &= state.root(ladder) == ladder.at(DEPTH) && state.tag() == tag;
    }
    cases.add(
        "every empty domain root is empty[256], so only field position binds it",
        "CE §7: an empty domain root has no leaves, so field position is the only binding",
        empty_domains_distinct,
        "all four empty domain roots are identical".to_owned(),
    );

    cases.0
}
