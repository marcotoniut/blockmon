//! Gate two: the generated expansion corpus, every recorded value recomputed.

use serde_json::Value;

use crate::harness::{
    Cmp, array_field, bool_field, hash_list, hex_bytes, hex_hash, raw_hash_list, text_field,
    u64_field,
};
use crate::hash::{Hash32, WORLD_V1, protocol_hash};
use crate::proof::{Claim, Invalid, LogicalProof, Malformed, Rejection, recompute, verify};
use crate::record::{Record, Tag};
use crate::tree::{DEPTH, DomainState, EmptyLadder, StateError, bit, climb, leaf_from_bytes};
use crate::world::WorldCommitmentV1;

/// One leaf hash plus 256 node hashes (CE §7 Cost).
const PER_KEY_RECOMPUTATION: u64 = 1 + DEPTH as u64;

pub struct Report {
    pub sections: Vec<Cmp>,
}

impl Report {
    pub fn passed(&self) -> usize {
        self.sections.iter().filter(|s| s.passed()).count()
    }

    pub fn compared(&self) -> usize {
        self.sections.iter().map(|s| s.compared).sum()
    }

    pub fn failures(&self) -> usize {
        self.sections.iter().map(|s| s.failures.len()).sum()
    }
}

fn tag_for_domain(name: &str) -> Tag {
    match name {
        "subject" => Tag::Subject,
        "blockmon" => Tag::Blockmon,
        "encounter" => Tag::Encounter,
        "supply" => Tag::Supply,
        other => panic!("corpus names an unratified domain {other:?}"),
    }
}

/// Build state from a recorded entry list, treating it as the ordered representation CE §7
/// describes: strictly ascending keys, unique, valid, identifier-bound.
fn state_from_entries(tag: Tag, entries: &[Value]) -> Result<DomainState, (usize, StateError)> {
    let pairs: Vec<(Vec<u8>, Vec<u8>)> = entries
        .iter()
        .map(|e| (hex_bytes(e, "key"), hex_bytes(e, "record_bytes")))
        .collect();
    DomainState::from_ordered(tag, &pairs).map_err(|e| (pairs.len(), e))
}

fn compare_proof(
    cmp: &mut Cmp,
    prefix: &str,
    proof: &Value,
    state: &DomainState,
    root: Hash32,
    ladder: &EmptyLadder,
) {
    let tag = tag_for_domain(text_field(proof, "domain"));
    cmp.number(
        &format!("{prefix}.tag"),
        u64_field(proof, "tag"),
        u64::from(tag.discriminant()),
    );
    let key = hex_hash(proof, "key");
    let present = bool_field(proof, "present");
    let level_zero = if present {
        leaf_from_bytes(tag.discriminant(), &key, &hex_bytes(proof, "record_bytes"))
    } else {
        ladder.at(0)
    };
    cmp.hash(
        &format!("{prefix}.leaf"),
        hex_hash(proof, "leaf"),
        level_zero,
    );
    cmp.hash(
        &format!("{prefix}.domain_root"),
        hex_hash(proof, "domain_root"),
        root,
    );

    let computed = state.siblings(ladder, &key);
    for (i, recorded) in raw_hash_list(proof, "siblings_leaf_to_root")
        .iter()
        .enumerate()
    {
        cmp.bytes(
            &format!("{prefix}.siblings_leaf_to_root[{i}]"),
            recorded,
            computed.get(i).map_or(&[][..], |h| &h[..]),
        );
    }
    cmp.hash(
        &format!("{prefix} climbs to the root"),
        root,
        climb(&key, level_zero, &hash_list(proof, "siblings_leaf_to_root")),
    );

    let logical = LogicalProof {
        tag: u8::try_from(u64_field(proof, "tag")).expect("tag fits in u8"),
        key: key.to_vec(),
        claim: if present {
            Claim::Present(hex_bytes(proof, "record_bytes"))
        } else {
            Claim::Absent
        },
        siblings: hash_list(proof, "siblings_leaf_to_root"),
    };
    let mut world = WorldCommitmentV1::default();
    world.set_root_for(tag, root);
    cmp.holds(
        &format!("{prefix} verifies"),
        verify(&logical, &root, &world, ladder).is_ok(),
    );
}

fn occupancy(doc: &Value, ladder: &EmptyLadder) -> Cmp {
    let mut cmp = Cmp::new("occupancy");
    for item in array_field(doc, "occupancy") {
        let tag = tag_for_domain(text_field(item, "domain"));
        let label = format!("{}[{}]", tag.domain_name(), u64_field(item, "count"));
        cmp.number(
            &format!("{label}.tag"),
            u64_field(item, "tag"),
            u64::from(tag.discriminant()),
        );
        let entries = array_field(item, "entries");
        cmp.number(
            &format!("{label}.count"),
            u64_field(item, "count"),
            entries.len() as u64,
        );
        match state_from_entries(tag, entries) {
            Ok(state) => {
                cmp.hash(
                    &format!("{label}.domain_root"),
                    hex_hash(item, "domain_root"),
                    state.root(ladder),
                );
            }
            Err((_, e)) => cmp.failures.push(format!(
                "{label}: entry list is not valid domain state: {e:?}"
            )),
        }
    }
    cmp
}

fn bit_boundary(doc: &Value, ladder: &EmptyLadder) -> Cmp {
    let mut cmp = Cmp::new("bit_boundary");
    for item in array_field(doc, "bit_boundary") {
        let index = usize::try_from(u64_field(item, "differing_bit")).expect("bit index");
        let label = format!("bit{index}");
        let base = hex_hash(item, "base_key");
        let flipped = hex_hash(item, "flipped_key");
        let differing: Vec<usize> = (0..DEPTH)
            .filter(|i| bit(&base, *i) != bit(&flipped, *i))
            .collect();
        cmp.holds(
            &format!("{label}: keys differ at exactly bit {index}"),
            differing == vec![index],
        );

        let tag = tag_for_domain(text_field(
            item.get("inclusion").expect("inclusion"),
            "domain",
        ));
        let entries = array_field(item, "entries");
        match state_from_entries(tag, entries) {
            Ok(state) => {
                let root = state.root(ladder);
                cmp.hash(
                    &format!("{label}.domain_root"),
                    hex_hash(item, "domain_root"),
                    root,
                );
                compare_proof(
                    &mut cmp,
                    &format!("{label}.inclusion"),
                    item.get("inclusion").expect("inclusion"),
                    &state,
                    root,
                    ladder,
                );
                compare_proof(
                    &mut cmp,
                    &format!("{label}.absence"),
                    item.get("absence").expect("absence"),
                    &state,
                    root,
                    ladder,
                );
            }
            Err((_, e)) => cmp
                .failures
                .push(format!("{label}: invalid domain state: {e:?}")),
        }
    }
    cmp
}

fn proofs(doc: &Value, ladder: &EmptyLadder) -> Cmp {
    let mut cmp = Cmp::new("proofs");
    for item in array_field(doc, "proofs") {
        let inclusion = item.get("inclusion").expect("inclusion");
        let tag = tag_for_domain(text_field(inclusion, "domain"));
        let entries = array_field(item, "entries");
        let label = format!("{}[{}]", tag.domain_name(), u64_field(item, "count"));
        cmp.number(
            &format!("{label}.count"),
            u64_field(item, "count"),
            entries.len() as u64,
        );
        match state_from_entries(tag, entries) {
            Ok(state) => {
                let root = state.root(ladder);
                compare_proof(
                    &mut cmp,
                    &format!("{label}.inclusion"),
                    inclusion,
                    &state,
                    root,
                    ladder,
                );
                compare_proof(
                    &mut cmp,
                    &format!("{label}.absence"),
                    item.get("absence").expect("absence"),
                    &state,
                    root,
                    ladder,
                );
            }
            Err((_, e)) => cmp
                .failures
                .push(format!("{label}: invalid domain state: {e:?}")),
        }
    }
    cmp
}

fn updates(doc: &Value, ladder: &EmptyLadder) -> Cmp {
    let mut cmp = Cmp::new("updates");
    for item in array_field(doc, "updates") {
        let tag = tag_for_domain(text_field(item, "domain"));
        let label = format!("{}[{}]", tag.domain_name(), u64_field(item, "count"));
        let key = hex_hash(item, "key");
        let entries = array_field(item, "entries_before");
        let Ok(before) = state_from_entries(tag, entries) else {
            cmp.failures
                .push(format!("{label}: invalid entries_before"));
            continue;
        };
        let root_before = before.root(ladder);
        cmp.hash(
            &format!("{label}.root_before"),
            hex_hash(item, "root_before"),
            root_before,
        );
        cmp.bytes(
            &format!("{label}.record_before"),
            &hex_bytes(item, "record_before"),
            &before
                .entries()
                .get(&key)
                .map(Record::encode)
                .unwrap_or_default(),
        );

        let mut pairs: Vec<(Vec<u8>, Vec<u8>)> = entries
            .iter()
            .map(|e| (hex_bytes(e, "key"), hex_bytes(e, "record_bytes")))
            .collect();
        let after_bytes = hex_bytes(item, "record_after");
        for pair in &mut pairs {
            if pair.0 == key.to_vec() {
                pair.1.clone_from(&after_bytes);
            }
        }
        let Ok(after) = DomainState::from_ordered(tag, &pairs) else {
            cmp.failures
                .push(format!("{label}: updated entries are not valid state"));
            continue;
        };
        let root_after = after.root(ladder);
        cmp.hash(
            &format!("{label}.root_after"),
            hex_hash(item, "root_after"),
            root_after,
        );
        cmp.number(
            &format!("{label}.keys_touched"),
            u64_field(item, "keys_touched"),
            1,
        );
        cmp.flag(
            &format!("{label}.siblings_unchanged"),
            bool_field(item, "siblings_unchanged"),
            before.siblings(ladder, &key) == after.siblings(ladder, &key),
        );
        cmp.holds(
            &format!("{label}: the root moved"),
            root_before != root_after,
        );
    }
    cmp
}

fn supply(doc: &Value, ladder: &EmptyLadder) -> Cmp {
    let mut cmp = Cmp::new("supply");
    let item = doc.get("supply").expect("supply section");
    cmp.bytes(
        "admissible_key",
        &hex_bytes(item, "admissible_key"),
        &[0u8; 32],
    );
    let entries = array_field(item, "entries");
    match state_from_entries(Tag::Supply, entries) {
        Ok(state) => {
            let root = state.root(ladder);
            cmp.hash("domain_root", hex_hash(item, "domain_root"), root);
            cmp.hash(
                "supply_commitment",
                hex_hash(item, "supply_commitment"),
                root,
            );
        }
        Err((_, e)) => cmp.failures.push(format!("supply entries invalid: {e:?}")),
    }
    let mut after = DomainState::empty(Tag::Supply);
    let after_bytes = hex_bytes(item, "record_after");
    match after.insert(&[0u8; 32], &after_bytes) {
        Ok(()) => cmp.hash(
            "root_after",
            hex_hash(item, "root_after"),
            after.root(ladder),
        ),
        Err(e) => cmp.failures.push(format!("record_after invalid: {e:?}")),
    }
    if let Ok(Record::Supply(s)) = Record::decode(Tag::Supply, &after_bytes) {
        cmp.holds(
            "record_after satisfies the supply accounting chain",
            s.accounting_chain_holds(),
        );
    } else {
        cmp.failures
            .push("record_after does not decode as Supply".to_owned());
    }
    cmp
}

fn world_commitments(doc: &Value, ladder: &EmptyLadder) -> Cmp {
    let mut cmp = Cmp::new("world_commitments");
    for item in array_field(doc, "world_commitments") {
        let label = format!("world[{}]", u64_field(item, "per_domain_count"));
        let state = item.get("state").expect("state");
        let mut world = WorldCommitmentV1::default();
        let mut ok = true;
        for tag in Tag::ALL {
            let entries = array_field(state, tag.domain_name());
            // The supply domain admits exactly the zero key (CE §7), so its occupancy is
            // capped at one however many keys the other domains carry.
            let expected = match tag {
                Tag::Supply => u64_field(item, "per_domain_count").min(1),
                Tag::Subject | Tag::Blockmon | Tag::Encounter => {
                    u64_field(item, "per_domain_count")
                }
            };
            cmp.number(
                &format!("{label}.{}.count", tag.domain_name()),
                expected,
                entries.len() as u64,
            );
            match state_from_entries(tag, entries) {
                Ok(domain) => world.set_root_for(tag, domain.root(ladder)),
                Err((_, e)) => {
                    ok = false;
                    cmp.failures
                        .push(format!("{label}.{}: {e:?}", tag.domain_name()));
                }
            }
        }
        if !ok {
            continue;
        }
        cmp.hash(
            &format!("{label}.subject_root"),
            hex_hash(item, "subject_root"),
            world.subject_root,
        );
        cmp.hash(
            &format!("{label}.blockmon_root"),
            hex_hash(item, "blockmon_root"),
            world.blockmon_root,
        );
        cmp.hash(
            &format!("{label}.encounter_root"),
            hex_hash(item, "encounter_root"),
            world.encounter_root,
        );
        cmp.hash(
            &format!("{label}.supply_root"),
            hex_hash(item, "supply_root"),
            world.supply_root,
        );
        cmp.bytes(
            &format!("{label}.world_commitment_bytes"),
            &hex_bytes(item, "world_commitment_bytes"),
            &world.encode(),
        );
        cmp.hash(
            &format!("{label}.world_root"),
            hex_hash(item, "world_root"),
            world.world_root(),
        );
    }
    cmp
}

#[expect(
    clippy::too_many_lines,
    reason = "one arm per recorded rejection kind keeps each auditable against its vector"
)]
fn rejections(doc: &Value, ladder: &EmptyLadder) -> Cmp {
    let mut cmp = Cmp::new("rejections");
    for item in array_field(doc, "rejections") {
        let kind = text_field(item, "kind");
        let recorded_class = text_field(item, "class");
        let (computed_class, detail_ok) = match kind {
            "sibling-count" => {
                let present = usize::try_from(u64_field(item, "siblings_present")).expect("count");
                cmp.number(
                    "sibling-count.required",
                    u64_field(item, "required"),
                    DEPTH as u64,
                );
                let proof = LogicalProof {
                    tag: Tag::Blockmon.discriminant(),
                    key: vec![0u8; 32],
                    claim: Claim::Absent,
                    siblings: vec![[0u8; 32]; present],
                };
                let rejection = recompute(&proof, ladder).err();
                (
                    rejection.map_or("accepted", Rejection::class),
                    rejection
                        == Some(Rejection::Malformed(Malformed::SiblingCount {
                            actual: present,
                        })),
                )
            }
            "unassigned-tag" => {
                let assigned: Vec<u64> = array_field(item, "assigned_tags")
                    .iter()
                    .map(|v| v.as_u64().expect("tag"))
                    .collect();
                cmp.holds("unassigned-tag.assigned_tags", assigned == vec![1, 2, 3, 4]);
                let mut all_malformed = true;
                let mut class = "malformed";
                for candidate in array_field(item, "tag_bytes") {
                    let tag = u8::try_from(candidate.as_u64().expect("tag byte")).expect("u8");
                    let proof = LogicalProof {
                        tag,
                        key: vec![0u8; 32],
                        claim: Claim::Absent,
                        siblings: vec![[0u8; 32]; DEPTH],
                    };
                    let rejection = recompute(&proof, ladder).err();
                    all_malformed &=
                        rejection == Some(Rejection::Malformed(Malformed::UnassignedTag { tag }));
                    class = rejection.map_or("accepted", Rejection::class);
                }
                (class, all_malformed)
            }
            "record-identifier-mismatch" => {
                // CE §7: malformedness covers domain-local record semantics. The
                // negative and its positive control both run, so the arm cannot
                // pass by rejecting everything.
                let tag = tag_for_domain(text_field(item, "domain"));
                let bytes = hex_bytes(item, "record_bytes");
                let key = hex_hash(item, "key");
                let recorded_id = hex_hash(item, "record_identifier");
                cmp.holds(
                    "record-identifier-mismatch.the record names another key",
                    recorded_id != key,
                );
                cmp.bytes(
                    "record-identifier-mismatch.identifier sits at the record's head",
                    &bytes[..32],
                    &recorded_id,
                );
                let unbound = LogicalProof {
                    tag: tag.discriminant(),
                    key: key.to_vec(),
                    claim: Claim::Present(bytes.clone()),
                    siblings: vec![[0u8; 32]; DEPTH],
                };
                let rejection = recompute(&unbound, ladder).err();
                let bound = LogicalProof {
                    tag: tag.discriminant(),
                    key: recorded_id.to_vec(),
                    claim: Claim::Present(bytes),
                    siblings: vec![[0u8; 32]; DEPTH],
                };
                let bound_ok = recompute(&bound, ladder).is_ok_and(|a| {
                    a.key == recorded_id
                        && a.record.and_then(|r| r.identifier()) == Some(recorded_id)
                });
                cmp.holds(
                    "record-identifier-mismatch.the bound record is accepted",
                    bound_ok,
                );
                (
                    rejection.map_or("accepted", Rejection::class),
                    rejection == Some(Rejection::Malformed(Malformed::IdentifierMismatch)),
                )
            }
            "record-width" => {
                let tag = tag_for_domain(text_field(item, "domain"));
                let bytes = hex_bytes(item, "record_bytes");
                cmp.number(
                    "record-width.required_width",
                    u64_field(item, "required_width"),
                    96,
                );
                cmp.holds(
                    "record-width.record is not the declared width",
                    bytes.len() != 96,
                );
                let proof = LogicalProof {
                    tag: tag.discriminant(),
                    key: hex_bytes(item, "record_bytes")
                        .get(..32)
                        .map(<[u8]>::to_vec)
                        .unwrap_or_default(),
                    claim: Claim::Present(bytes),
                    siblings: vec![[0u8; 32]; DEPTH],
                };
                let rejection = recompute(&proof, ladder).err();
                (
                    rejection.map_or("accepted", Rejection::class),
                    matches!(
                        rejection,
                        Some(Rejection::Malformed(Malformed::RecordDecode(_)))
                    ),
                )
            }
            "supply-key" => {
                cmp.bytes(
                    "supply-key.admissible_key",
                    &hex_bytes(item, "admissible_key"),
                    &[0u8; 32],
                );
                let key = hex_bytes(item, "key");
                let proof = LogicalProof {
                    tag: Tag::Supply.discriminant(),
                    key: key.clone(),
                    claim: Claim::Absent,
                    siblings: vec![[0u8; 32]; DEPTH],
                };
                let rejection = recompute(&proof, ladder).err();
                let state_rejects = DomainState::empty(Tag::Supply)
                    .insert(&key, &[0u8; 40])
                    .err()
                    == Some(StateError::SupplyKeyNotZero);
                (
                    rejection.map_or("accepted", Rejection::class),
                    rejection == Some(Rejection::Malformed(Malformed::SupplyKeyNotZero))
                        && state_rejects,
                )
            }
            "domain-root-mismatch" => {
                let tag = tag_for_domain(text_field(item, "domain"));
                let entries = array_field(item, "entries");
                let claimed = hex_hash(item, "claimed_domain_root");
                match state_from_entries(tag, entries) {
                    Ok(state) => {
                        let root = state.root(ladder);
                        cmp.hash(
                            "domain-root-mismatch.recomputed_domain_root",
                            hex_hash(item, "recomputed_domain_root"),
                            root,
                        );
                        cmp.holds("domain-root-mismatch: claimed differs", claimed != root);
                        let key = hex_bytes(
                            entries[0].get("key").map_or(&Value::Null, |_| &entries[0]),
                            "key",
                        );
                        let record = hex_bytes(&entries[0], "record_bytes");
                        let key32: Hash32 = key.as_slice().try_into().expect("32-byte key");
                        let proof = LogicalProof {
                            tag: tag.discriminant(),
                            key,
                            claim: Claim::Present(record),
                            siblings: state.siblings(ladder, &key32),
                        };
                        let mut world = WorldCommitmentV1::default();
                        world.set_root_for(tag, claimed);
                        let rejection = verify(&proof, &claimed, &world, ladder).err();
                        (
                            rejection.map_or("accepted", |r| match r {
                                Rejection::Malformed(_) => "malformed",
                                Rejection::Invalid(_) => "well-formed but invalid",
                            }),
                            rejection == Some(Rejection::Invalid(Invalid::RootMismatch)),
                        )
                    }
                    Err((_, e)) => {
                        cmp.failures
                            .push(format!("domain-root-mismatch entries invalid: {e:?}"));
                        ("malformed", false)
                    }
                }
            }
            "wrong-commitment-position" => {
                let correct = hex_bytes(item, "correct_bytes");
                let transposed = hex_bytes(item, "transposed_bytes");
                cmp.hash(
                    "wrong-commitment-position.correct_world_root",
                    hex_hash(item, "correct_world_root"),
                    protocol_hash(WORLD_V1, &correct),
                );
                cmp.hash(
                    "wrong-commitment-position.transposed_world_root",
                    hex_hash(item, "transposed_world_root"),
                    protocol_hash(WORLD_V1, &transposed),
                );
                let fields = |bytes: &[u8]| -> Vec<Hash32> {
                    (0..4)
                        .map(|i| {
                            let mut f = [0u8; 32];
                            f.copy_from_slice(&bytes[i * 32..(i + 1) * 32]);
                            f
                        })
                        .collect()
                };
                let a = fields(&correct);
                let b = fields(&transposed);
                let transposition = text_field(item, "transposition");
                let exchanged = a[0] == b[0] && a[1] == b[1] && a[2] == b[3] && a[3] == b[2];
                cmp.text(
                    "wrong-commitment-position.transposition",
                    transposition,
                    "encounter_root and supply_root exchanged",
                );
                let correct_world = WorldCommitmentV1 {
                    subject_root: a[0],
                    blockmon_root: a[1],
                    encounter_root: a[2],
                    supply_root: a[3],
                };
                let transposed_world = WorldCommitmentV1 {
                    subject_root: b[0],
                    blockmon_root: b[1],
                    encounter_root: b[2],
                    supply_root: b[3],
                };
                let misreads = correct_world.root_for(Tag::Encounter)
                    != transposed_world.root_for(Tag::Encounter);
                (
                    "well-formed but invalid",
                    exchanged
                        && misreads
                        && correct_world.world_root() != transposed_world.world_root(),
                )
            }
            other => {
                cmp.failures
                    .push(format!("unhandled rejection kind {other:?}"));
                ("", false)
            }
        };
        cmp.text(&format!("{kind}.class"), recorded_class, computed_class);
        cmp.holds(
            &format!("{kind}: reproduced with the listed reason"),
            detail_ok,
        );
    }
    cmp
}

/// The CE §7 Cost accounting, re-derived: reads and writes come from the CE §6 precondition
/// list and its consume-on-attempt rule, hashes from one leaf plus 256 nodes per key.
fn authenticated_access(doc: &Value) -> Cmp {
    let mut cmp = Cmp::new("transition1_authenticated_access");
    let section = doc
        .get("transition1_authenticated_access")
        .expect("section");

    let accounting = section.get("accounting").expect("accounting");
    cmp.number(
        "accounting.per_key_recomputation",
        u64_field(accounting, "per_key_recomputation"),
        PER_KEY_RECOMPUTATION,
    );
    cmp.number(
        "accounting.world_commitment_hash",
        u64_field(accounting, "world_commitment_hash"),
        1,
    );

    // CE §6 preconditions read subjects, the named permit, and supply.
    let reads = section.get("reads").expect("reads");
    let expected_reads = [("subject", 1u64), ("encounter", 1), ("supply", 1)];
    let mut total_reads = 0;
    for (domain, count) in expected_reads {
        cmp.number(&format!("reads.{domain}"), u64_field(reads, domain), count);
        total_reads += count;
    }
    cmp.number("reads.total", u64_field(reads, "total"), total_reads);
    cmp.number(
        "reads.full_state_kernel_hashes",
        u64_field(reads, "full_state_kernel_hashes"),
        0,
    );
    cmp.number(
        "reads.stateless_verify_hashes",
        u64_field(reads, "stateless_verify_hashes"),
        total_reads * PER_KEY_RECOMPUTATION,
    );

    // CE §7 Cost: a rejected transition incurs no state-recomputation hash.
    let rejected = section.get("rejected").expect("rejected");
    cmp.number("rejected.total", u64_field(rejected, "total"), 0);
    cmp.number(
        "rejected.write_recomputation_hashes",
        u64_field(rejected, "write_recomputation_hashes"),
        0,
    );
    cmp.holds(
        "rejected.writes is empty",
        array_field(rejected, "writes").is_empty(),
    );

    // CE §6: once the roll executes, the permit and one capability are consumed
    // unconditionally; only a CREATED outcome adds a blockmon key.
    for (outcome, keys) in [("roll_failed", 2u64), ("created", 3)] {
        let branch = section.get(outcome).expect("outcome branch");
        cmp.number(
            &format!("{outcome}.total"),
            u64_field(branch, "total"),
            keys,
        );
        cmp.number(
            &format!("{outcome}.writes length"),
            array_field(branch, "writes").len() as u64,
            keys,
        );
        cmp.number(
            &format!("{outcome}.write_recomputation_hashes"),
            u64_field(branch, "write_recomputation_hashes"),
            keys * PER_KEY_RECOMPUTATION + 1,
        );
    }

    let bound = section.get("bound").expect("bound");
    cmp.number(
        "bound.max_keys_read",
        u64_field(bound, "max_keys_read"),
        total_reads,
    );
    cmp.number(
        "bound.max_keys_written",
        u64_field(bound, "max_keys_written"),
        3,
    );
    cmp.number(
        "bound.max_write_recomputation_hashes",
        u64_field(bound, "max_write_recomputation_hashes"),
        3 * PER_KEY_RECOMPUTATION + 1,
    );
    cmp.number(
        "bound.max_stateless_verify_hashes",
        u64_field(bound, "max_stateless_verify_hashes"),
        total_reads * PER_KEY_RECOMPUTATION,
    );
    cmp.flag(
        "bound.independent_of_state_size",
        bool_field(bound, "independent_of_state_size"),
        true,
    );
    cmp
}

pub fn run(doc: &Value, ladder: &EmptyLadder) -> Report {
    let mut sections = Vec::new();
    let mut preamble = Cmp::new("preamble");
    preamble.number("depth", u64_field(doc, "depth"), DEPTH as u64);
    preamble.text(
        "commitment_version",
        text_field(doc, "commitment_version"),
        WORLD_V1,
    );
    sections.push(preamble);
    sections.push(occupancy(doc, ladder));
    sections.push(bit_boundary(doc, ladder));
    sections.push(proofs(doc, ladder));
    sections.push(updates(doc, ladder));
    sections.push(supply(doc, ladder));
    sections.push(world_commitments(doc, ladder));
    sections.push(rejections(doc, ladder));
    sections.push(authenticated_access(doc));
    Report { sections }
}
