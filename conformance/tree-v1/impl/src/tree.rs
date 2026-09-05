//! CE §7 construction: depth-256 sparse Merkle tree, per-level empty ladder, no path
//! collapse.

use std::collections::BTreeMap;

use crate::codec::DecodeError;
use crate::hash::{Hash32, SMT_EMPTY, SMT_LEAF, SMT_NODE, protocol_hash};
use crate::record::{Record, Tag};

pub const DEPTH: usize = 256;

/// `bit(i)` is bit position `i mod 8` counted from zero at the most significant bit of
/// byte `i / 8` (CE §7).
pub const fn bit(key: &Hash32, i: usize) -> u8 {
    (key[i / 8] >> (7 - (i % 8))) & 1
}

pub fn node(left: &Hash32, right: &Hash32) -> Hash32 {
    let mut payload = [0u8; 64];
    payload[..32].copy_from_slice(left);
    payload[32..].copy_from_slice(right);
    protocol_hash(SMT_NODE, &payload)
}

/// `u8(tag) ‖ key ‖ record_bytes`. Taking the record bytes directly keeps leaf construction
/// separable from record validity, which CE §7 treats as two conditions.
pub fn leaf_from_bytes(tag: u8, key: &Hash32, record_bytes: &[u8]) -> Hash32 {
    let mut payload = Vec::with_capacity(1 + 32 + record_bytes.len());
    payload.push(tag);
    payload.extend_from_slice(key);
    payload.extend_from_slice(record_bytes);
    protocol_hash(SMT_LEAF, &payload)
}

pub fn leaf(tag: Tag, key: &Hash32, record: &Record) -> Hash32 {
    leaf_from_bytes(tag.discriminant(), key, &record.encode())
}

/// `empty[0]` under `smt-empty`, `empty[d+1] = node(empty[d], empty[d])` for `d` in
/// `[0, 256)`, so index 256 is an empty domain's root.
pub struct EmptyLadder {
    levels: [Hash32; DEPTH + 1],
}

impl EmptyLadder {
    pub fn compute() -> Self {
        let mut levels = [[0u8; 32]; DEPTH + 1];
        levels[0] = protocol_hash(SMT_EMPTY, b"");
        for d in 0..DEPTH {
            levels[d + 1] = node(&levels[d], &levels[d]);
        }
        Self { levels }
    }

    pub const fn at(&self, level: usize) -> Hash32 {
        self.levels[level]
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StateError {
    KeyLength { actual: usize },
    DuplicateKey,
    NotStrictlyAscending,
    Record(DecodeError),
    IdentifierMismatch,
    SupplyKeyNotZero,
}

/// CE §7 / PR §1 domain state: a finite mapping from 32-byte key to record.
pub struct DomainState {
    tag: Tag,
    entries: BTreeMap<Hash32, Record>,
}

impl DomainState {
    pub const fn empty(tag: Tag) -> Self {
        Self {
            tag,
            entries: BTreeMap::new(),
        }
    }

    pub const fn tag(&self) -> Tag {
        self.tag
    }

    pub const fn entries(&self) -> &BTreeMap<Hash32, Record> {
        &self.entries
    }

    /// Insert under the CE §7 domain-state conditions: 32-byte key, unique, record valid
    /// for the domain, identifier equal to the key where the record carries one, and the
    /// zero key alone in the supply domain.
    pub fn insert(&mut self, key: &[u8], record_bytes: &[u8]) -> Result<(), StateError> {
        let key: Hash32 = key
            .try_into()
            .map_err(|_| StateError::KeyLength { actual: key.len() })?;
        if matches!(self.tag, Tag::Supply) && key != [0u8; 32] {
            return Err(StateError::SupplyKeyNotZero);
        }
        let record = Record::decode(self.tag, record_bytes).map_err(StateError::Record)?;
        if record.identifier().is_some_and(|id| id != key) {
            return Err(StateError::IdentifierMismatch);
        }
        if self.entries.insert(key, record).is_some() {
            return Err(StateError::DuplicateKey);
        }
        Ok(())
    }

    /// CE §7: an ordered representation has keys strictly ascending byte-lexicographically.
    pub fn from_ordered(tag: Tag, pairs: &[(Vec<u8>, Vec<u8>)]) -> Result<Self, StateError> {
        let mut state = Self::empty(tag);
        let mut previous: Option<Hash32> = None;
        for (key, record_bytes) in pairs {
            state.insert(key, record_bytes)?;
            let current: Hash32 = key
                .as_slice()
                .try_into()
                .map_err(|_| StateError::KeyLength { actual: key.len() })?;
            if previous.is_some_and(|p| p >= current) {
                return Err(StateError::NotStrictlyAscending);
            }
            previous = Some(current);
        }
        Ok(state)
    }

    /// A mapping presentation: uniqueness is required, ordering is not.
    pub fn from_mapping(tag: Tag, pairs: &[(Vec<u8>, Vec<u8>)]) -> Result<Self, StateError> {
        let mut state = Self::empty(tag);
        for (key, record_bytes) in pairs {
            state.insert(key, record_bytes)?;
        }
        Ok(state)
    }

    fn leaves(&self) -> Vec<(Hash32, Hash32)> {
        self.entries
            .iter()
            .map(|(k, r)| (*k, leaf(self.tag, k, r)))
            .collect()
    }

    pub fn root(&self, ladder: &EmptyLadder) -> Hash32 {
        subtree(ladder, 0, &self.leaves())
    }

    /// The 256 sibling commitments for `key`, ordered leaf to root (CE §7 Proofs).
    pub fn siblings(&self, ladder: &EmptyLadder, key: &Hash32) -> Vec<Hash32> {
        let leaves = self.leaves();
        let mut here = leaves.as_slice();
        let mut out = Vec::with_capacity(DEPTH);
        for i in 0..DEPTH {
            let split = here.partition_point(|(k, _)| bit(k, i) == 0);
            let (zero, one) = here.split_at(split);
            let (mine, other) = if bit(key, i) == 0 {
                (zero, one)
            } else {
                (one, zero)
            };
            out.push(subtree(ladder, i + 1, other));
            here = mine;
        }
        out.reverse();
        out
    }
}

/// Value at level `DEPTH - i` of the subtree whose first `i` path bits are already fixed.
fn subtree(ladder: &EmptyLadder, i: usize, leaves: &[(Hash32, Hash32)]) -> Hash32 {
    if leaves.is_empty() {
        return ladder.at(DEPTH - i);
    }
    if i == DEPTH {
        debug_assert_eq!(leaves.len(), 1, "unique keys collapse to one level-0 slot");
        return leaves[0].1;
    }
    let split = leaves.partition_point(|(k, _)| bit(k, i) == 0);
    let (zero, one) = leaves.split_at(split);
    node(&subtree(ladder, i + 1, zero), &subtree(ladder, i + 1, one))
}

/// Climb from a level-0 value to the domain root. Step `d` combines with `siblings[d]`
/// under `bit(255 - d)`: `0` puts the running value on the left (CE §7).
/// `climb` over recorded data: a wrong-length sibling list is a failure the
/// caller reports, not a panic.
pub fn climb_recorded(
    key: &Hash32,
    level_zero: Hash32,
    siblings: &[Hash32],
) -> Result<Hash32, usize> {
    if siblings.len() == DEPTH {
        Ok(climb(key, level_zero, siblings))
    } else {
        Err(siblings.len())
    }
}

pub fn climb(key: &Hash32, level_zero: Hash32, siblings: &[Hash32]) -> Hash32 {
    let mut current = level_zero;
    for (d, sibling) in siblings.iter().enumerate() {
        current = if bit(key, DEPTH - 1 - d) == 0 {
            node(&current, sibling)
        } else {
            node(sibling, &current)
        };
    }
    current
}

#[cfg(test)]
mod tests {
    use super::{DEPTH, DomainState, EmptyLadder, StateError, bit, climb, leaf, node};
    use crate::record::{Record, Tag};

    fn key_of(byte0: u8) -> [u8; 32] {
        let mut k = [0u8; 32];
        k[0] = byte0;
        k
    }

    #[test]
    fn bit_zero_is_the_most_significant_bit_of_byte_zero() {
        let mut key = [0u8; 32];
        key[0] = 0b1000_0000;
        assert_eq!(bit(&key, 0), 1);
        assert_eq!(bit(&key, 1), 0);

        key[0] = 0b0000_0001;
        assert_eq!(bit(&key, 0), 0);
        assert_eq!(bit(&key, 7), 1);

        key[31] = 0b0000_0001;
        assert_eq!(bit(&key, 255), 1);
        assert_eq!(bit(&key, 248), 0);
    }

    #[test]
    fn empty_ladder_levels_are_pairwise_distinct_and_root_is_level_256() {
        let ladder = EmptyLadder::compute();
        let mut seen = std::collections::BTreeSet::new();
        for level in 0..=DEPTH {
            assert!(
                seen.insert(ladder.at(level)),
                "level {level} repeats an earlier commitment"
            );
        }
        assert_eq!(
            DomainState::empty(Tag::Subject).root(&ladder),
            ladder.at(DEPTH)
        );
        assert_eq!(
            DomainState::empty(Tag::Supply).root(&ladder),
            ladder.at(DEPTH)
        );
    }

    #[test]
    fn single_key_root_is_256_nodes_above_its_leaf_with_no_collapse() {
        let ladder = EmptyLadder::compute();
        let key = key_of(0x00);
        let mut state = DomainState::empty(Tag::Subject);
        state.insert(&key, &[]).expect("unit record");

        let mut expected = leaf(Tag::Subject, &key, &Record::Subject);
        for d in 0..DEPTH {
            expected = node(&expected, &ladder.at(d));
        }
        assert_eq!(state.root(&ladder), expected);
        assert_ne!(
            state.root(&ladder),
            leaf(Tag::Subject, &key, &Record::Subject)
        );
    }

    #[test]
    fn key_of_all_ones_walks_right_at_every_level() {
        let ladder = EmptyLadder::compute();
        let key = [0xffu8; 32];
        let mut state = DomainState::empty(Tag::Subject);
        state.insert(&key, &[]).expect("unit record");

        let mut expected = leaf(Tag::Subject, &key, &Record::Subject);
        for d in 0..DEPTH {
            expected = node(&ladder.at(d), &expected);
        }
        assert_eq!(state.root(&ladder), expected);
    }

    #[test]
    fn siblings_climb_back_to_the_root_for_present_and_absent_keys() {
        let ladder = EmptyLadder::compute();
        let mut state = DomainState::empty(Tag::Subject);
        for byte0 in [0x00u8, 0x01, 0x80, 0xff, 0x7f] {
            state.insert(&key_of(byte0), &[]).expect("unit record");
        }
        let root = state.root(&ladder);

        for byte0 in [0x00u8, 0x01, 0x80, 0xff, 0x7f] {
            let key = key_of(byte0);
            let siblings = state.siblings(&ladder, &key);
            assert_eq!(siblings.len(), DEPTH);
            let level_zero = leaf(Tag::Subject, &key, &Record::Subject);
            assert_eq!(climb(&key, level_zero, &siblings), root);
        }

        for byte0 in [0x02u8, 0x40, 0xfe] {
            let key = key_of(byte0);
            let siblings = state.siblings(&ladder, &key);
            assert_eq!(climb(&key, ladder.at(0), &siblings), root);
        }
    }

    #[test]
    fn root_is_independent_of_presentation_order() {
        let ladder = EmptyLadder::compute();
        let forward: Vec<(Vec<u8>, Vec<u8>)> = [0x11u8, 0x22, 0x33]
            .iter()
            .map(|b| (key_of(*b).to_vec(), Vec::new()))
            .collect();
        let mut reverse = forward.clone();
        reverse.reverse();

        let a = DomainState::from_mapping(Tag::Subject, &forward).expect("valid");
        let b = DomainState::from_mapping(Tag::Subject, &reverse).expect("valid");
        assert_eq!(a.root(&ladder), b.root(&ladder));

        assert_eq!(
            DomainState::from_ordered(Tag::Subject, &reverse).err(),
            Some(StateError::NotStrictlyAscending)
        );
        assert_eq!(
            DomainState::from_ordered(Tag::Subject, &forward)
                .map(|s| s.root(&ladder))
                .ok(),
            Some(a.root(&ladder))
        );
    }

    #[test]
    fn domain_state_conditions_are_enforced() {
        let mut short_key = DomainState::empty(Tag::Subject);
        assert_eq!(
            short_key.insert(&[0u8; 31], &[]),
            Err(StateError::KeyLength { actual: 31 })
        );

        let mut duplicate = DomainState::empty(Tag::Subject);
        duplicate.insert(&key_of(1), &[]).expect("first");
        assert_eq!(
            duplicate.insert(&key_of(1), &[]),
            Err(StateError::DuplicateKey)
        );

        let mut supply = DomainState::empty(Tag::Supply);
        assert_eq!(
            supply.insert(&key_of(1), &[0u8; 40]),
            Err(StateError::SupplyKeyNotZero)
        );
        supply
            .insert(&[0u8; 32], &[0u8; 40])
            .expect("zero key admitted");

        let mut blockmon = DomainState::empty(Tag::Blockmon);
        let mut record = vec![0u8; 96];
        record[0] = 0xaa;
        assert_eq!(
            blockmon.insert(&key_of(1), &record),
            Err(StateError::IdentifierMismatch)
        );
        let mut bound = vec![0u8; 96];
        bound[0] = 1;
        blockmon
            .insert(&key_of(1), &bound)
            .expect("creature_id equals key");
    }

    #[test]
    fn tag_binds_into_every_leaf_so_domains_do_not_share_roots() {
        let ladder = EmptyLadder::compute();
        let key = [0u8; 32];
        let mut subject = DomainState::empty(Tag::Subject);
        subject.insert(&key, &[]).expect("unit");
        let mut supply = DomainState::empty(Tag::Supply);
        supply.insert(&key, &[0u8; 40]).expect("zero key");
        assert_ne!(subject.root(&ladder), supply.root(&ladder));
    }
}
