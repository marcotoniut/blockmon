//! Gate one: the 16 hand-derived checks, every recorded value recomputed.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::harness::{
    Cmp, array_field, bool_field, decode_hex, hash_list, hex_bytes, hex_hash, raw_hash_list,
    text_field, u64_field,
};
use crate::hash::{Hash32, SMT_EMPTY, SMT_LEAF, SMT_NODE, WORLD_V1, protocol_hash};
use crate::proof::{Claim, Invalid, LogicalProof, Malformed, Rejection, recompute, verify};
use crate::record::{Record, Tag};
use crate::tree::{DEPTH, DomainState, EmptyLadder, climb_recorded, leaf_from_bytes};
use crate::world::WorldCommitmentV1;

pub struct Report {
    pub checks: Vec<Cmp>,
    pub preamble: Cmp,
}

impl Report {
    pub fn passed(&self) -> usize {
        self.checks.iter().filter(|c| c.passed()).count()
    }

    pub fn compared(&self) -> usize {
        self.preamble.compared + self.checks.iter().map(|c| c.compared).sum::<usize>()
    }
}

fn tag_of(value: u64) -> Tag {
    Tag::from_discriminant(u8::try_from(value).expect("tag fits in u8"))
        .unwrap_or_else(|| panic!("vector names an unassigned tag {value}"))
}

/// Keys only; a subject record is the empty byte string.
fn subject_state(keys: &[Value]) -> DomainState {
    let mut state = DomainState::empty(Tag::Subject);
    for key in keys {
        let key = decode_hex(key.as_str().expect("subject key"));
        state.insert(&key, &[]).expect("valid subject entry");
    }
    state
}

fn keyed_state(tag: Tag, entries: &[Value]) -> DomainState {
    let mut state = DomainState::empty(tag);
    for entry in entries {
        let key = hex_bytes(entry, "key");
        let record_bytes = hex_bytes(entry, "record_bytes");
        state
            .insert(&key, &record_bytes)
            .expect("valid entry for its domain");
    }
    state
}

fn compare_entry_leaves(cmp: &mut Cmp, tag: Tag, entries: &[Value]) {
    for (i, entry) in entries.iter().enumerate() {
        if entry.get("leaf").is_none() {
            continue;
        }
        let key = hex_hash(entry, "key");
        let record_bytes = hex_bytes(entry, "record_bytes");
        cmp.hash(
            &format!("entries[{i}].leaf"),
            hex_hash(entry, "leaf"),
            leaf_from_bytes(tag.discriminant(), &key, &record_bytes),
        );
    }
}

fn logical_proof(proof: &Value) -> LogicalProof {
    let present = bool_field(proof, "present");
    LogicalProof {
        tag: u8::try_from(u64_field(proof, "tag")).expect("tag fits in u8"),
        key: hex_bytes(proof, "key"),
        claim: if present {
            Claim::Present(hex_bytes(proof, "record_bytes"))
        } else {
            Claim::Absent
        },
        siblings: hash_list(proof, "siblings_leaf_to_root"),
    }
}

/// The recorded `leaf` of a proof is a cross-check, not proof content: CE §7 has the
/// verifier compute the level-0 value itself.
fn compare_proof_level_zero(cmp: &mut Cmp, proof: &Value, ladder: &EmptyLadder) -> Hash32 {
    let key = hex_hash(proof, "key");
    let tag = u8::try_from(u64_field(proof, "tag")).expect("tag fits in u8");
    let computed = if bool_field(proof, "present") {
        leaf_from_bytes(tag, &key, &hex_bytes(proof, "record_bytes"))
    } else {
        ladder.at(0)
    };
    cmp.hash("proof.leaf", hex_hash(proof, "leaf"), computed);
    computed
}

fn compare_siblings(cmp: &mut Cmp, recorded: &[Vec<u8>], computed: &[Hash32]) {
    for (i, sibling) in recorded.iter().enumerate() {
        match computed.get(i) {
            Some(mine) => cmp.bytes(&format!("siblings_leaf_to_root[{i}]"), sibling, mine),
            None => cmp.bytes(&format!("siblings_leaf_to_root[{i}]"), sibling, b""),
        }
    }
}

pub fn run(doc: &Value, ladder: &EmptyLadder) -> Report {
    let mut preamble = Cmp::new("preamble");
    let construction = doc.get("construction").expect("construction block");
    preamble.number(
        "construction.depth",
        u64_field(construction, "depth"),
        DEPTH as u64,
    );
    let domains = construction.get("domains").expect("domains");
    for (field, mine) in [
        ("leaf", SMT_LEAF),
        ("node", SMT_NODE),
        ("empty", SMT_EMPTY),
        ("world", WORLD_V1),
    ] {
        preamble.text(
            &format!("domains.{field}"),
            text_field(domains, field),
            mine,
        );
    }
    let tags = construction.get("tags").expect("tags");
    for tag in Tag::ALL {
        preamble.number(
            &format!("tags.{}", tag.domain_name()),
            u64_field(tags, tag.domain_name()),
            u64::from(tag.discriminant()),
        );
    }
    let empties = doc.get("empty_constants").expect("empty_constants");
    for level in [0usize, 1, 2, 254, 255, 256] {
        let field = format!("empty_{level}");
        preamble.hash(&field, hex_hash(empties, &field), ladder.at(level));
    }

    let mut states: BTreeMap<Hash32, (Tag, DomainState)> = BTreeMap::new();
    let mut checks = Vec::new();
    for check in array_field(doc, "checks") {
        checks.push(run_check(check, ladder, &mut states));
    }
    Report { checks, preamble }
}

#[expect(
    clippy::too_many_lines,
    reason = "one arm per constitutional check keeps each check auditable against its vector"
)]
fn run_check(
    check: &Value,
    ladder: &EmptyLadder,
    states: &mut BTreeMap<Hash32, (Tag, DomainState)>,
) -> Cmp {
    let name = text_field(check, "name");
    let mut cmp = Cmp::new(name);
    match name {
        "empty-domain-root" => {
            let tag = tag_of(u64_field(check, "tag"));
            let state = DomainState::empty(tag);
            let root = state.root(ladder);
            cmp.hash("domain_root", hex_hash(check, "domain_root"), root);
            cmp.holds("root equals empty[256]", root == ladder.at(DEPTH));
            cmp.holds(
                "entries are empty",
                array_field(check, "entries").is_empty(),
            );
        }
        "single-leaf" | "divergence-bit-0" | "divergence-bit-255" => {
            let proof = check.get("proof").expect("proof");
            let tag = tag_of(u64_field(proof, "tag"));
            let entries = array_field(check, "entries");
            compare_entry_leaves(&mut cmp, tag, entries);
            let state = keyed_state(tag, entries);
            let root = state.root(ladder);
            if check.get("domain_root").is_some() {
                cmp.hash("domain_root", hex_hash(check, "domain_root"), root);
            }
            cmp.hash("proof.domain_root", hex_hash(proof, "domain_root"), root);

            let level_zero = compare_proof_level_zero(&mut cmp, proof, ladder);
            let key = hex_hash(proof, "key");
            let computed = state.siblings(ladder, &key);
            compare_siblings(
                &mut cmp,
                &raw_hash_list(proof, "siblings_leaf_to_root"),
                &computed,
            );
            match climb_recorded(&key, level_zero, &hash_list(proof, "siblings_leaf_to_root")) {
                Ok(recomputed) => cmp.hash("root from recorded siblings", root, recomputed),
                Err(n) => cmp
                    .failures
                    .push(format!("recorded siblings: {n}, not {DEPTH}")),
            }
            let logical = logical_proof(proof);
            let mut world = WorldCommitmentV1::default();
            world.set_root_for(tag, root);
            cmp.holds(
                "verify accepts",
                verify(&logical, &root, &world, ladder).is_ok(),
            );
            states.insert(root, (tag, state));
        }
        "same-record-different-keys" => {
            let tag = tag_of(u64_field(check, "tag"));
            let entries = array_field(check, "entries");
            compare_entry_leaves(&mut cmp, tag, entries);
            let leaves: Vec<Hash32> = entries
                .iter()
                .map(|e| {
                    leaf_from_bytes(
                        tag.discriminant(),
                        &hex_hash(e, "key"),
                        &hex_bytes(e, "record_bytes"),
                    )
                })
                .collect();
            cmp.flag(
                "leaves_differ",
                bool_field(check, "leaves_differ"),
                leaves[0] != leaves[1],
            );
            let state = keyed_state(tag, entries);
            let root = state.root(ladder);
            cmp.hash("domain_root", hex_hash(check, "domain_root"), root);
            cmp.holds(
                "subject records are the empty byte string",
                entries
                    .iter()
                    .all(|e| hex_bytes(e, "record_bytes").is_empty()),
            );
            states.insert(root, (tag, state));
        }
        "same-key-record-different-tags" => {
            let key = hex_hash(check, "key");
            let record_bytes = hex_bytes(check, "record_bytes");
            let two = leaf_from_bytes(2, &key, &record_bytes);
            let three = leaf_from_bytes(3, &key, &record_bytes);
            cmp.hash("leaf_tag_2", hex_hash(check, "leaf_tag_2"), two);
            cmp.hash("leaf_tag_3", hex_hash(check, "leaf_tag_3"), three);
            cmp.flag(
                "leaves_differ",
                bool_field(check, "leaves_differ"),
                two != three,
            );
        }
        "leaf-node-domain-separation" => {
            let payload = hex_bytes(check, "payload");
            let under_leaf = protocol_hash(SMT_LEAF, &payload);
            let under_node = protocol_hash(SMT_NODE, &payload);
            cmp.hash(
                "under_leaf_domain",
                hex_hash(check, "under_leaf_domain"),
                under_leaf,
            );
            cmp.hash(
                "under_node_domain",
                hex_hash(check, "under_node_domain"),
                under_node,
            );
            cmp.flag(
                "differ",
                bool_field(check, "differ"),
                under_leaf != under_node,
            );
        }
        "absence-unoccupied-key" | "absence-adjacent-key" => {
            let proof = check.get("proof").expect("proof");
            let tag = tag_of(u64_field(proof, "tag"));
            let root = hex_hash(proof, "domain_root");
            let level_zero = compare_proof_level_zero(&mut cmp, proof, ladder);
            cmp.holds(
                "absent level-0 slot is empty[0]",
                level_zero == ladder.at(0),
            );
            let key = hex_hash(proof, "key");
            let recorded = hash_list(proof, "siblings_leaf_to_root");
            match climb_recorded(&key, level_zero, &recorded) {
                Ok(recomputed) => cmp.hash("root from recorded siblings", root, recomputed),
                Err(n) => cmp
                    .failures
                    .push(format!("recorded siblings: {n}, not {DEPTH}")),
            }
            if let Some((state_tag, state)) = states.get(&root) {
                cmp.holds("state association tag", *state_tag == tag);
                compare_siblings(
                    &mut cmp,
                    &raw_hash_list(proof, "siblings_leaf_to_root"),
                    &state.siblings(ladder, &key),
                );
            } else {
                cmp.failures
                    .push("no earlier check declares this domain root".to_owned());
            }
            let logical = logical_proof(proof);
            let mut world = WorldCommitmentV1::default();
            world.set_root_for(tag, root);
            cmp.holds(
                "verify accepts",
                verify(&logical, &root, &world, ladder).is_ok(),
            );
            if check.get("domain_root_matches_single_leaf").is_some() {
                cmp.flag(
                    "domain_root_matches_single_leaf",
                    bool_field(check, "domain_root_matches_single_leaf"),
                    states.contains_key(&root),
                );
            }
        }
        "malformed-sibling-count" => {
            let proof = check.get("proof").expect("proof");
            let recorded = raw_hash_list(proof, "siblings_leaf_to_root");
            let logical = logical_proof(proof);
            let rejection = recompute(&logical, ladder).err();
            cmp.text(
                "rejection_class",
                text_field(check, "rejection_class"),
                rejection.map_or("accepted", Rejection::class),
            );
            cmp.holds(
                "sibling-count malformed",
                rejection
                    == Some(Rejection::Malformed(Malformed::SiblingCount {
                        actual: recorded.len(),
                    })),
            );
            compare_proof_level_zero(&mut cmp, proof, ladder);
            let root = hex_hash(proof, "domain_root");
            match states.get(&root) {
                Some((_, state)) => {
                    let full = state.siblings(ladder, &hex_hash(proof, "key"));
                    compare_siblings(&mut cmp, &recorded, &full);
                    cmp.holds(
                        "recorded list is the correct list minus its root-side entry",
                        recorded.len() + 1 == full.len(),
                    );
                }
                None => cmp
                    .failures
                    .push("no earlier check declares this domain root".to_owned()),
            }
        }
        "malformed-record-trailing-byte" => {
            let tag = tag_of(u64_field(check, "tag"));
            let record_bytes = hex_bytes(check, "record_bytes");
            let key = hex_bytes(check, "key");
            let logical = LogicalProof {
                tag: tag.discriminant(),
                key: key.clone(),
                claim: Claim::Present(record_bytes.clone()),
                siblings: vec![[0u8; 32]; DEPTH],
            };
            let rejection = recompute(&logical, ladder).err();
            cmp.text(
                "rejection_class",
                text_field(check, "rejection_class"),
                rejection.map_or("accepted", Rejection::class),
            );
            cmp.holds(
                "record decode is the malformed reason",
                matches!(
                    rejection,
                    Some(Rejection::Malformed(Malformed::RecordDecode(_)))
                ),
            );
            cmp.holds(
                "domain state rejects it too",
                DomainState::empty(tag).insert(&key, &record_bytes).is_err(),
            );
            cmp.number("note width", 97, record_bytes.len() as u64);
        }
        "invalid-domain-root-mismatch" => {
            let proof = check.get("proof").expect("proof");
            let claimed = hex_hash(check, "claimed_domain_root");
            let level_zero = compare_proof_level_zero(&mut cmp, proof, ladder);
            let key = hex_hash(proof, "key");
            let recorded = hash_list(proof, "siblings_leaf_to_root");
            let Ok(recomputed) = climb_recorded(&key, level_zero, &recorded) else {
                cmp.failures.push(format!(
                    "recorded siblings: {}, not {DEPTH}",
                    recorded.len()
                ));
                return cmp;
            };
            cmp.hash(
                "recomputed_domain_root",
                hex_hash(check, "recomputed_domain_root"),
                recomputed,
            );
            let logical = logical_proof(proof);
            let mut world = WorldCommitmentV1::default();
            world.set_root_for(tag_of(u64_field(proof, "tag")), claimed);
            let rejection = verify(&logical, &claimed, &world, ladder).err();
            cmp.text(
                "rejection_class",
                text_field(check, "rejection_class"),
                rejection.map_or("accepted", |r| match r {
                    Rejection::Malformed(_) => "malformed",
                    Rejection::Invalid(_) => "well-formed but invalid",
                }),
            );
            cmp.holds(
                "root mismatch is the reason",
                rejection == Some(Rejection::Invalid(Invalid::RootMismatch)),
            );
            if let Some((_, state)) = states.get(&recomputed) {
                compare_siblings(
                    &mut cmp,
                    &raw_hash_list(proof, "siblings_leaf_to_root"),
                    &state.siblings(ladder, &key),
                );
            } else {
                cmp.failures
                    .push("no earlier check declares the recomputed root".to_owned());
            }
        }
        "world-commitment" => {
            let state = check.get("state").expect("state");
            let subject = subject_state(array_field(state, "subject"));
            let blockmon = keyed_state(Tag::Blockmon, array_field(state, "blockmon"));
            let encounter = keyed_state(Tag::Encounter, array_field(state, "encounter"));
            let supply_entry = state.get("supply").expect("supply");
            let supply_bytes = hex_bytes(supply_entry, "record_bytes");
            let mut supply = DomainState::empty(Tag::Supply);
            supply
                .insert(&hex_bytes(supply_entry, "key"), &supply_bytes)
                .expect("valid supply entry");

            let world = WorldCommitmentV1 {
                subject_root: subject.root(ladder),
                blockmon_root: blockmon.root(ladder),
                encounter_root: encounter.root(ladder),
                supply_root: supply.root(ladder),
            };
            let roots = check.get("domain_roots").expect("domain_roots");
            cmp.hash(
                "subject_root",
                hex_hash(roots, "subject_root"),
                world.subject_root,
            );
            cmp.hash(
                "blockmon_root",
                hex_hash(roots, "blockmon_root"),
                world.blockmon_root,
            );
            cmp.hash(
                "encounter_root",
                hex_hash(roots, "encounter_root"),
                world.encounter_root,
            );
            cmp.hash(
                "supply_root",
                hex_hash(roots, "supply_root"),
                world.supply_root,
            );
            cmp.bytes(
                "world_commitment_bytes",
                &hex_bytes(check, "world_commitment_bytes"),
                &world.encode(),
            );
            cmp.hash(
                "world_root",
                hex_hash(check, "world_root"),
                world.world_root(),
            );

            let created = if let Ok(Record::Supply(s)) = Record::decode(Tag::Supply, &supply_bytes)
            {
                cmp.holds("supply accounting chain", s.accounting_chain_holds());
                s.created
            } else {
                cmp.failures
                    .push("supply record does not decode".to_owned());
                0
            };
            cmp.number(
                "extant == created",
                created,
                blockmon.entries().len() as u64,
            );
            states.insert(world.subject_root, (Tag::Subject, subject));
            states.insert(world.blockmon_root, (Tag::Blockmon, blockmon));
            states.insert(world.encounter_root, (Tag::Encounter, encounter));
            states.insert(world.supply_root, (Tag::Supply, supply));
        }
        "invalid-wrong-commitment-position" => {
            let permuted = hex_bytes(check, "world_commitment_bytes");
            cmp.number("permuted preimage width", 128, permuted.len() as u64);
            cmp.hash(
                "world_root",
                hex_hash(check, "world_root"),
                protocol_hash(WORLD_V1, &permuted),
            );
            let correct = hex_hash(check, "correct_world_root");
            cmp.holds(
                "permutation changes world_root",
                hex_hash(check, "world_root") != correct,
            );
            cmp.text(
                "rejection_class",
                text_field(check, "rejection_class"),
                "well-formed but invalid",
            );

            let mut fields: Vec<Hash32> = Vec::new();
            for i in 0..4 {
                let mut field = [0u8; 32];
                field.copy_from_slice(&permuted[i * 32..(i + 1) * 32]);
                fields.push(field);
            }
            let transposed = WorldCommitmentV1 {
                subject_root: fields[0],
                blockmon_root: fields[2],
                encounter_root: fields[1],
                supply_root: fields[3],
            };
            cmp.hash("correct_world_root", correct, transposed.world_root());
            cmp.holds(
                "blockmon and encounter roots are the transposed pair",
                states.get(&fields[1]).map(|(t, _)| *t) == Some(Tag::Encounter)
                    && states.get(&fields[2]).map(|(t, _)| *t) == Some(Tag::Blockmon),
            );

            let key = [0u8; 32];
            let (_, blockmon) = states
                .get(&transposed.blockmon_root)
                .expect("blockmon state from the world-commitment check");
            let record_bytes = blockmon
                .entries()
                .get(&key)
                .map(Record::encode)
                .expect("the blockmon key of the world-commitment check");
            let logical = LogicalProof {
                tag: Tag::Blockmon.discriminant(),
                key: key.to_vec(),
                claim: Claim::Present(record_bytes),
                siblings: blockmon.siblings(ladder, &key),
            };
            let mut misplaced = transposed;
            misplaced.blockmon_root = fields[1];
            misplaced.encounter_root = fields[2];
            cmp.holds(
                "verify rejects the misplaced root as invalid",
                verify(&logical, &transposed.blockmon_root, &misplaced, ladder)
                    == Err(Rejection::Invalid(Invalid::NotAtAssignedPosition)),
            );
        }
        "supply-singleton" => {
            let tag = tag_of(u64_field(check, "tag"));
            let entries = array_field(check, "entries");
            compare_entry_leaves(&mut cmp, tag, entries);
            let state = keyed_state(tag, entries);
            let root = state.root(ladder);
            cmp.hash("domain_root", hex_hash(check, "domain_root"), root);
            cmp.hash(
                "supply_commitment",
                hex_hash(check, "supply_commitment"),
                root,
            );
            cmp.holds(
                "the only key is 32 zero bytes",
                entries.iter().all(|e| hex_bytes(e, "key") == vec![0u8; 32]),
            );
        }
        "malformed-supply-key" => {
            let tag = tag_of(u64_field(check, "tag"));
            let key = hex_bytes(check, "key");
            let logical = LogicalProof {
                tag: tag.discriminant(),
                key: key.clone(),
                claim: Claim::Present(vec![0u8; 40]),
                siblings: vec![[0u8; 32]; DEPTH],
            };
            let rejection = recompute(&logical, ladder).err();
            cmp.text(
                "rejection_class",
                text_field(check, "rejection_class"),
                rejection.map_or("accepted", Rejection::class),
            );
            cmp.holds(
                "supply key is the malformed reason",
                rejection == Some(Rejection::Malformed(Malformed::SupplyKeyNotZero)),
            );
            cmp.holds(
                "domain state rejects it too",
                DomainState::empty(tag).insert(&key, &[0u8; 40]).is_err(),
            );
        }
        other => cmp.failures.push(format!("unhandled check name {other:?}")),
    }
    cmp
}
