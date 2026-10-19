//! The v1 world commitment of a `WorldV0` value (canonical-encoding.md §7).

use crate::encoding::{DecodeError, Hash32, ZERO32};
use crate::kernel::Write;
use crate::smt::{self, Invalid, ProofError, Store, Tag, Update, WorldCommitmentV1};
use crate::t1::WorldV0;

/// Each domain's `(key, level-0 commitment)` pairs, strictly ascending by key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DomainLeaves {
    pub subject: Vec<(Hash32, Hash32)>,
    pub blockmon: Vec<(Hash32, Hash32)>,
    pub encounter: Vec<(Hash32, Hash32)>,
    pub supply: Vec<(Hash32, Hash32)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateKey {
    pub tag: Tag,
    pub key: Hash32,
}

/// An entry listed twice with the same record denotes the same mapping as one listing; only
/// two different records at one key leave the value there undefined (protocol.md §1).
fn sorted_unique(
    tag: Tag,
    mut v: Vec<(Hash32, Hash32)>,
) -> Result<Vec<(Hash32, Hash32)>, DuplicateKey> {
    v.sort_unstable();
    v.dedup();
    if let Some(w) = v.windows(2).find(|w| w[0].0 == w[1].0) {
        return Err(DuplicateKey { tag, key: w[0].0 });
    }
    Ok(v)
}

/// A domain's `(key, encode(record))` entries as the representation lists them.
fn entries(world: &WorldV0, tag: Tag) -> Vec<(Hash32, Vec<u8>)> {
    match tag {
        Tag::Subject => world.subjects.iter().map(|k| (*k, Vec::new())).collect(),
        Tag::Blockmon => world
            .blockmon
            .iter()
            .map(|b| (b.creature_id, b.encode()))
            .collect(),
        Tag::Encounter => world
            .permits
            .iter()
            .map(|p| (p.permit_id, p.encode()))
            .collect(),
        Tag::Supply => vec![(ZERO32, world.supply.encode())],
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError {
    Structure(DecodeError),
    NoMapping(DuplicateKey),
}

/// The §6 state reader for kernel input. Exactly three forms are kept for `INVALID_STATE` to
/// reject: unsorted listings, identical repeats and unassigned discriminants. Bytes that fail to
/// frame as a listing (truncation, a count exceeding the remaining input, trailing bytes) and a
/// listing that denotes no mapping are refused before any transition.
pub fn read_state(bytes: &[u8]) -> Result<WorldV0, ReadError> {
    let w = WorldV0::read_listing(bytes).map_err(ReadError::Structure)?;
    conflicting_key(&w).map_or(Ok(w), |e| Err(ReadError::NoMapping(e)))
}

/// A key listed with two different records, which denotes no mapping (§7).
pub fn conflicting_key(world: &WorldV0) -> Option<DuplicateKey> {
    [Tag::Subject, Tag::Blockmon, Tag::Encounter, Tag::Supply]
        .into_iter()
        .find_map(|tag| {
            let mut v = entries(world, tag);
            v.sort_unstable();
            v.dedup();
            v.windows(2)
                .find(|w| w[0].0 == w[1].0)
                .map(|w| DuplicateKey { tag, key: w[0].0 })
        })
}

fn leaves(world: &WorldV0, tag: Tag) -> Result<Vec<(Hash32, Hash32)>, DuplicateKey> {
    let v = entries(world, tag)
        .into_iter()
        .map(|(k, r)| (k, smt::leaf(tag, &k, &r)))
        .collect();
    sorted_unique(tag, v)
}

impl DomainLeaves {
    /// State is a mapping, not a sequence: the leaf set is taken from the records whatever
    /// order the representation lists them in.
    pub fn of(world: &WorldV0) -> Result<Self, DuplicateKey> {
        Ok(Self {
            subject: leaves(world, Tag::Subject)?,
            blockmon: leaves(world, Tag::Blockmon)?,
            encounter: leaves(world, Tag::Encounter)?,
            supply: leaves(world, Tag::Supply)?,
        })
    }

    pub fn get(&self, tag: Tag) -> &[(Hash32, Hash32)] {
        match tag {
            Tag::Subject => &self.subject,
            Tag::Blockmon => &self.blockmon,
            Tag::Encounter => &self.encounter,
            Tag::Supply => &self.supply,
        }
    }

    pub fn commitment(&self) -> WorldCommitmentV1 {
        WorldCommitmentV1 {
            subject_root: smt::root(&self.subject),
            blockmon_root: smt::root(&self.blockmon),
            encounter_root: smt::root(&self.encounter),
            supply_root: smt::root(&self.supply),
        }
    }
}

pub fn commit(world: &WorldV0) -> Result<WorldCommitmentV1, DuplicateKey> {
    DomainLeaves::of(world).map(|l| l.commitment())
}

/// One materialised tree per domain, holding leaf commitments and no records; the records stay in
/// the kernel's materialised world (protocol.md §2). Only genesis reads the full world; every
/// later touched key takes its siblings from here.
#[derive(Debug, Clone)]
pub struct WorldStore {
    subject: Store,
    blockmon: Store,
    encounter: Store,
    supply: Store,
}

impl WorldStore {
    pub fn genesis(world: &WorldV0) -> Result<Self, DuplicateKey> {
        Ok(Self {
            subject: Store::of(&leaves(world, Tag::Subject)?),
            blockmon: Store::of(&leaves(world, Tag::Blockmon)?),
            encounter: Store::of(&leaves(world, Tag::Encounter)?),
            supply: Store::of(&leaves(world, Tag::Supply)?),
        })
    }

    pub const fn domain(&self, tag: Tag) -> &Store {
        match tag {
            Tag::Subject => &self.subject,
            Tag::Blockmon => &self.blockmon,
            Tag::Encounter => &self.encounter,
            Tag::Supply => &self.supply,
        }
    }

    const fn domain_mut(&mut self, tag: Tag) -> &mut Store {
        match tag {
            Tag::Subject => &mut self.subject,
            Tag::Blockmon => &mut self.blockmon,
            Tag::Encounter => &mut self.encounter,
            Tag::Supply => &mut self.supply,
        }
    }

    pub fn commitment(&self) -> WorldCommitmentV1 {
        WorldCommitmentV1 {
            subject_root: self.subject.root(),
            blockmon_root: self.blockmon.root(),
            encounter_root: self.encounter.root(),
            supply_root: self.supply.root(),
        }
    }

    /// The producer's move: holding the domain state it knows the pre-state root, so each write
    /// climbs once (§7). A malformed value is refused first, then an old value whose level-0
    /// commitment is not the one the store holds, before the write climbs or changes anything.
    pub fn advance(&mut self, writes: &[Write]) -> Result<WorldCommitmentV1, ProofError> {
        for w in writes {
            let (tag, key) = (w.at.tag, w.at.key);
            let tree = self.domain_mut(tag);
            let (old, new) =
                smt::admitted_level_zero(tag, &key, w.old.as_deref(), w.new.as_deref())
                    .map_err(ProofError::Malformed)?;
            if tree.level_zero(&key) != old {
                return Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor));
            }
            tree.set(&key, new);
        }
        Ok(self.commitment())
    }

    /// The same writes checked as a verifier without domain state checks them: each a §7 update
    /// anchored in the domain root the previous one left, climbing twice.
    pub fn verify_updates(&mut self, writes: &[Write]) -> Result<WorldCommitmentV1, ProofError> {
        for w in writes {
            let (tag, key) = (w.at.tag, w.at.key);
            let tree = self.domain_mut(tag);
            let siblings = tree.siblings(&key);
            let root = smt::apply_update(&Update {
                tag: tag as u8,
                key: &key,
                old: w.old.as_deref(),
                new: w.new.as_deref(),
                siblings: &siblings,
                claimed_pre_root: tree.root(),
            })?;
            let level_zero = w
                .new
                .as_deref()
                .map_or_else(|| smt::empty(0), |b| smt::leaf(tag, &key, b));
            assert_eq!(
                tree.set(&key, level_zero),
                root,
                "store path disagrees with the update climb"
            );
        }
        Ok(self.commitment())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoding::protocol_hash;
    use crate::t1::{BlockmonRecord, PermitRecord, Supply};

    fn world() -> WorldV0 {
        WorldV0 {
            subjects: vec![[1; 32], [9; 32]],
            blockmon: vec![BlockmonRecord {
                creature_id: [3; 32],
                owner: [1; 32],
                origin_permit: [4; 32],
            }],
            permits: vec![PermitRecord {
                permit_id: [5; 32],
                subject: [1; 32],
                encounter_class: 1,
                expiry_position: 10,
                status: 1,
            }],
            supply: Supply {
                epoch: 1,
                envelope: 5,
                minted: 3,
                consumed: 1,
                created: 1,
            },
        }
    }

    #[test]
    fn commitment_bytes_are_the_four_roots_in_field_order() {
        let c = commit(&world()).unwrap_or_else(|e| panic!("{e:?}"));
        let b = c.encode();
        assert_eq!(b.len(), 128);
        assert_eq!(&b[..32], &c.subject_root);
        assert_eq!(&b[32..64], &c.blockmon_root);
        assert_eq!(&b[64..96], &c.encounter_root);
        assert_eq!(&b[96..], &c.supply_root);
        assert_eq!(c.world_root(), protocol_hash("blockmon/world/v1", &b));
        assert_eq!(c.supply_commitment(), c.supply_root);
    }

    #[test]
    fn domain_roots_use_their_own_tags() {
        let w = world();
        let c = commit(&w).unwrap_or_else(|e| panic!("{e:?}"));
        let k = [3; 32];
        let as_subject = smt::root(&[(k, smt::leaf(Tag::Subject, &k, &[]))]);
        assert_ne!(c.blockmon_root, as_subject);
        let supply_leaf = smt::leaf(Tag::Supply, &ZERO32, &w.supply.encode());
        assert_eq!(c.supply_root, smt::root(&[(ZERO32, supply_leaf)]));
        let empty = WorldV0 {
            subjects: vec![],
            blockmon: vec![],
            permits: vec![],
            ..w
        };
        let ce = commit(&empty).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(ce.subject_root, smt::empty(smt::DEPTH));
        assert_eq!(ce.blockmon_root, smt::empty(smt::DEPTH));
        assert_eq!(ce.encounter_root, smt::empty(smt::DEPTH));
    }

    #[test]
    fn listing_order_does_not_change_the_commitment() {
        let w = world();
        let mut r = w.clone();
        r.subjects.reverse();
        assert_eq!(commit(&w), commit(&r));
    }

    #[test]
    fn invalid_but_encodable_state_still_commits() {
        let mut w = world();
        w.permits[0].status = 0;
        w.supply.created = 9;
        let c = commit(&w).unwrap_or_else(|e| panic!("{e:?}"));
        let leaf = smt::leaf(Tag::Encounter, &[5; 32], &w.permits[0].encode());
        assert_eq!(c.encounter_root, smt::root(&[([5; 32], leaf)]));
        assert_eq!(w.permits[0].encode()[73], 0);
    }

    #[test]
    fn advancing_by_the_kernel_writes_matches_full_derivation() {
        use crate::kernel::{tests::fixture, transition};
        let (w, cmd, ctx, m) = fixture();
        for rate in [0, 10_000] {
            let m = crate::t1::ManifestV0 {
                catch_rate_bp: rate,
                ..m
            };
            let t = transition(&w, &cmd, &ctx, &m);
            let pre = WorldStore::genesis(&w).unwrap_or_else(|e| panic!("{e:?}"));
            assert_eq!(Some(pre.commitment()), commit(&w).ok());
            assert_eq!(pre.clone().advance(&t.writes).ok(), commit(&t.next).ok());
            assert_eq!(
                pre.clone().verify_updates(&t.writes).ok(),
                commit(&t.next).ok()
            );
            let mut stale = t.writes.clone();
            stale[0].old = t.writes[0].new.clone();
            let refused = Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor));
            let mut producer = pre.clone();
            assert_eq!(producer.advance(&stale), refused);
            assert_eq!(producer.commitment(), pre.commitment());
            assert_eq!(pre.clone().verify_updates(&stale), refused);
            let mut unassigned = t.writes.clone();
            if let Some(old) = unassigned[0].old.as_mut() {
                old[73] = 0;
            }
            let malformed = Err(ProofError::Malformed(smt::Malformed::RecordEncoding(
                crate::encoding::DecodeError::UnassignedEnum(0),
            )));
            let mut producer = pre.clone();
            assert_eq!(producer.advance(&unassigned), malformed);
            assert_eq!(producer.commitment(), pre.commitment());
            assert_eq!(pre.clone().verify_updates(&unassigned), malformed);
            let mut late = t.writes.clone();
            late[1].old = t.writes[1].new.clone();
            let mut producer = pre.clone();
            assert_eq!(producer.advance(&late), refused);
            assert_eq!(
                producer.commitment().supply_root,
                pre.commitment().supply_root
            );
            let mut verifier = pre.clone();
            assert_eq!(verifier.verify_updates(&late), refused);
            assert_eq!(
                verifier.commitment().supply_root,
                pre.commitment().supply_root
            );
            let mut both = stale.clone();
            if let Some(new) = both[0].new.as_mut() {
                new[73] = 0;
            }
            let mut producer = pre.clone();
            assert_eq!(producer.advance(&both), malformed);
            assert_eq!(producer.commitment(), pre.commitment());
            assert_eq!(pre.clone().verify_updates(&both), malformed);
        }
    }

    /// Hashes spent moving the commitment as the producer, then as anchored updates.
    fn hashes_to_advance(w: &WorldV0) -> (usize, usize) {
        use crate::kernel::{tests::fixture, transition};
        let (_, cmd, ctx, m) = fixture();
        let t = transition(w, &cmd, &ctx, &m);
        assert_eq!(t.writes.len(), 3);
        let mut store = WorldStore::genesis(w).unwrap_or_else(|e| panic!("{e:?}"));
        let hashes = || crate::encoding::HASHES.with(std::cell::Cell::get);
        let before = hashes();
        let moved = store.clone().advance(&t.writes).ok();
        let root = moved.map(|c| c.world_root());
        let producer = hashes() - before;
        let before = hashes();
        let anchored = store.verify_updates(&t.writes).ok();
        let verifier = hashes() - before;
        assert_eq!(moved, commit(&t.next).ok());
        assert_eq!(anchored, moved);
        assert_eq!(root, commit(&t.next).ok().map(|c| c.world_root()));
        (producer, verifier)
    }

    #[test]
    fn moving_the_commitment_costs_the_same_at_any_population() {
        use crate::kernel::tests::{PERMIT, SUBJECT, fixture};
        let (small, ..) = fixture();
        let mut large = small.clone();
        let mut neighbour = PERMIT;
        neighbour[31] ^= 1;
        let mut ids: Vec<Hash32> = (0..300u16)
            .map(|i| protocol_hash("blockmon/test/v0", &i.to_be_bytes()))
            .chain([neighbour])
            .collect();
        ids.sort_unstable();
        for id in &ids {
            large.subjects.push(*id);
            large.permits.push(PermitRecord {
                permit_id: *id,
                subject: SUBJECT,
                ..small.permits[0].clone()
            });
            large.blockmon.push(BlockmonRecord {
                creature_id: *id,
                owner: SUBJECT,
                origin_permit: *id,
            });
        }
        large.subjects.sort_unstable();
        large.permits.sort_unstable_by_key(|p| p.permit_id);
        let n = u64::try_from(ids.len()).unwrap_or(u64::MAX);
        large.supply = Supply {
            created: n,
            consumed: n,
            minted: n + 1,
            envelope: n + 1,
            ..small.supply
        };
        assert_eq!(
            crate::kernel::validity_violation(&large, &fixture().3),
            None
        );
        let (producer, anchored) = hashes_to_advance(&small);
        assert_eq!((producer, anchored), hashes_to_advance(&large));
        assert_eq!(producer, 3 * (1 + smt::DEPTH) + 2 + 1);
        assert!(anchored > producer);
    }

    #[test]
    fn the_state_reader_keeps_what_invalid_state_rejects() {
        use crate::encoding::DecodeError;
        use crate::kernel::{tests::fixture, transition};
        use crate::t1::RejectReason;
        let (w, cmd, ctx, m) = fixture();
        assert_eq!(WorldV0::decode(&w.encode()), Ok(w.clone()));
        assert_eq!(read_state(&w.encode()), Ok(w.clone()));
        let mut unsorted = w.clone();
        unsorted.subjects.reverse();
        let mut repeated = w.clone();
        repeated.permits.push(w.permits[0].clone());
        let mut unassigned = w.clone();
        unassigned.permits[0].status = 0;
        for (kept, strict) in [
            (unsorted, DecodeError::NonCanonicalOrder),
            (repeated, DecodeError::NonCanonicalOrder),
            (unassigned, DecodeError::UnassignedEnum(0)),
        ] {
            let bytes = kept.encode();
            assert_eq!(WorldV0::decode(&bytes), Err(strict));
            assert_eq!(read_state(&bytes), Ok(kept.clone()));
            let t = transition(&kept, &cmd, &ctx, &m);
            assert_eq!(t.effects.reject_reason, Some(RejectReason::InvalidState));
            assert_eq!(
                crate::invariants::check(&kept, &cmd, &ctx, &m, &t),
                Vec::<String>::new()
            );
        }
        let mut conflicting = w.clone();
        let mut other = w.permits[0].clone();
        other.status = 2;
        conflicting.permits.push(other);
        assert!(matches!(
            read_state(&conflicting.encode()),
            Err(ReadError::NoMapping(_))
        ));
        let mut bytes = w.encode();
        bytes.push(0);
        assert_eq!(
            read_state(&bytes),
            Err(ReadError::Structure(DecodeError::TrailingBytes(1)))
        );
        bytes.truncate(bytes.len() - 2);
        assert_eq!(
            read_state(&bytes),
            Err(ReadError::Structure(DecodeError::Truncated))
        );
        let mut overcount = w.encode();
        overcount[..4].copy_from_slice(&u32::MAX.to_be_bytes());
        assert_eq!(
            read_state(&overcount),
            Err(ReadError::Structure(DecodeError::LengthExceedsInput))
        );
    }

    #[test]
    fn a_repeated_identical_entry_commits_its_mapping() {
        let mut w = world();
        w.subjects.push([1; 32]);
        w.permits.push(w.permits[0].clone());
        w.blockmon.insert(0, w.blockmon[0].clone());
        assert_eq!(conflicting_key(&w), None);
        assert_eq!(commit(&w), commit(&world()));
    }

    #[test]
    fn conflicting_records_at_one_key_are_not_a_mapping() {
        let mut w = world();
        assert_eq!(conflicting_key(&w), None);
        w.permits.push(w.permits[0].clone());
        assert_eq!(conflicting_key(&w), None);
        let mut other = w.permits[0].clone();
        other.status = 2;
        w.permits.push(other);
        let refused = DuplicateKey {
            tag: Tag::Encounter,
            key: [5; 32],
        };
        assert_eq!(conflicting_key(&w), Some(refused.clone()));
        assert_eq!(commit(&w), Err(refused));
    }
}
