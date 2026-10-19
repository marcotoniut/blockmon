//! Authenticated state tree v1, construction v0 (canonical-encoding.md §7).

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::encoding::{DecodeError, Encoder, Hash32, ZERO32, protocol_hash, protocol_hash_parts};
use crate::t1::{BlockmonRecord, PermitRecord, Supply};

pub const DOMAIN_SMT_LEAF: &str = "blockmon/smt-leaf/v0";
pub const DOMAIN_SMT_NODE: &str = "blockmon/smt-node/v0";
pub const DOMAIN_SMT_EMPTY: &str = "blockmon/smt-empty/v0";
pub const DOMAIN_WORLD_V1: &str = "blockmon/world/v1";

pub const DEPTH: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Tag {
    Subject = 1,
    Blockmon = 2,
    Encounter = 3,
    Supply = 4,
}

impl Tag {
    pub const fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::Subject),
            2 => Some(Self::Blockmon),
            3 => Some(Self::Encounter),
            4 => Some(Self::Supply),
            _ => None,
        }
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Subject => "subject",
            Self::Blockmon => "blockmon",
            Self::Encounter => "encounter",
            Self::Supply => "supply",
        }
    }
}

fn empty_table() -> &'static [Hash32; DEPTH + 1] {
    static TABLE: OnceLock<[Hash32; DEPTH + 1]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut t = [ZERO32; DEPTH + 1];
        t[0] = protocol_hash(DOMAIN_SMT_EMPTY, b"");
        for d in 0..DEPTH {
            t[d + 1] = node(&t[d], &t[d]);
        }
        t
    })
}

pub fn empty(level: usize) -> Hash32 {
    empty_table()[level]
}

pub fn node(left: &Hash32, right: &Hash32) -> Hash32 {
    protocol_hash_parts(DOMAIN_SMT_NODE, &[left, right])
}

/// `record` is `encode(record)`; for the unit subject record it is empty, with no length prefix.
pub fn leaf(tag: Tag, key: &Hash32, record: &[u8]) -> Hash32 {
    protocol_hash_parts(DOMAIN_SMT_LEAF, &[&[tag as u8], key, record])
}

/// Bit `i mod 8` from the most significant bit of byte `i / 8`.
pub const fn bit(key: &Hash32, i: usize) -> u8 {
    (key[i / 8] >> (7 - (i % 8))) & 1
}

/// `(key, level-0 commitment)` pairs, strictly ascending by key.
pub type Leaves = [(Hash32, Hash32)];

/// The commitment of the subtree at `level` holding `items`, which share the path bits above it.
fn subtree(level: usize, items: &Leaves) -> Hash32 {
    if items.is_empty() {
        return empty(level);
    }
    if level == 0 {
        debug_assert_eq!(items.len(), 1);
        return items[0].1;
    }
    let i = DEPTH - level;
    let split = items.partition_point(|(k, _)| bit(k, i) == 0);
    node(
        &subtree(level - 1, &items[..split]),
        &subtree(level - 1, &items[split..]),
    )
}

/// Full derivation of a domain root from its leaf set.
pub fn root(items: &Leaves) -> Hash32 {
    assert!(
        items.windows(2).all(|w| w[0].0 < w[1].0),
        "leaf keys must be strictly ascending"
    );
    subtree(DEPTH, items)
}

/// The 256 sibling commitments on `key`'s path, ordered leaf to root.
pub fn siblings(items: &Leaves, key: &Hash32) -> Vec<Hash32> {
    assert!(
        items.windows(2).all(|w| w[0].0 < w[1].0),
        "leaf keys must be strictly ascending"
    );
    let mut out = vec![ZERO32; DEPTH];
    let mut cur = items;
    for level in (1..=DEPTH).rev() {
        let i = DEPTH - level;
        let split = cur.partition_point(|(k, _)| bit(k, i) == 0);
        let (left, right) = cur.split_at(split);
        let (path, other) = if bit(key, i) == 0 {
            (left, right)
        } else {
            (right, left)
        };
        out[level - 1] = subtree(level - 1, other);
        cur = path;
    }
    out
}

pub fn root_from(key: &Hash32, level_zero: &Hash32, siblings: &[Hash32]) -> Hash32 {
    let mut cur = *level_zero;
    for (j, sib) in siblings.iter().enumerate() {
        cur = if bit(key, DEPTH - 1 - j) == 0 {
            node(&cur, sib)
        } else {
            node(sib, &cur)
        };
    }
    cur
}

/// `key` with every bit from position `bits` on cleared: the path to its level `DEPTH - bits` node.
fn prefix(key: &Hash32, bits: usize) -> Hash32 {
    let mut out = ZERO32;
    let whole = bits / 8;
    out[..whole].copy_from_slice(&key[..whole]);
    if !bits.is_multiple_of(8) {
        out[whole] = key[whole] & (0xff << (8 - bits % 8));
    }
    out
}

const fn flip(mut key: Hash32, i: usize) -> Hash32 {
    key[i / 8] ^= 0x80 >> (i % 8);
    key
}

/// A materialised domain tree: every node by `(level, path)`, an absent entry standing for that
/// level's empty commitment. Reading a key's siblings or re-hashing its path takes `DEPTH` steps
/// whatever the population, which a walk over the leaf set does not.
#[derive(Debug, Clone, Default)]
pub struct Store {
    nodes: HashMap<(usize, Hash32), Hash32>,
}

impl Store {
    /// Genesis: the only step that reads the whole leaf set.
    pub fn of(items: &Leaves) -> Self {
        let mut s = Self::default();
        for (k, lz) in items {
            s.set(k, *lz);
        }
        s
    }

    fn get(&self, level: usize, path: &Hash32) -> Hash32 {
        self.nodes
            .get(&(level, *path))
            .copied()
            .unwrap_or_else(|| empty(level))
    }

    pub fn root(&self) -> Hash32 {
        self.get(DEPTH, &ZERO32)
    }

    /// The level-0 slot at `key`: its leaf commitment, or `empty[0]` when absent.
    pub fn level_zero(&self, key: &Hash32) -> Hash32 {
        self.get(0, key)
    }

    /// The 256 sibling commitments on `key`'s path, ordered leaf to root.
    pub fn siblings(&self, key: &Hash32) -> Vec<Hash32> {
        (0..DEPTH)
            .map(|j| self.get(j, &flip(prefix(key, DEPTH - j), DEPTH - 1 - j)))
            .collect()
    }

    /// Writes `level_zero` at `key`, re-hashes its path and returns the new root.
    pub fn set(&mut self, key: &Hash32, level_zero: Hash32) -> Hash32 {
        let siblings = self.siblings(key);
        let mut cur = level_zero;
        self.put(0, *key, cur);
        for (j, sib) in siblings.iter().enumerate() {
            cur = if bit(key, DEPTH - 1 - j) == 0 {
                node(&cur, sib)
            } else {
                node(sib, &cur)
            };
            self.put(j + 1, prefix(key, DEPTH - 1 - j), cur);
        }
        cur
    }

    fn put(&mut self, level: usize, path: Hash32, value: Hash32) {
        if value == empty(level) {
            self.nodes.remove(&(level, path));
        } else {
            self.nodes.insert((level, path), value);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(
    clippy::struct_field_names,
    reason = "the field names are the specification's"
)]
pub struct WorldCommitmentV1 {
    pub subject_root: Hash32,
    pub blockmon_root: Hash32,
    pub encounter_root: Hash32,
    pub supply_root: Hash32,
}

impl WorldCommitmentV1 {
    pub fn encode(&self) -> Vec<u8> {
        Encoder::new()
            .hash32(&self.subject_root)
            .hash32(&self.blockmon_root)
            .hash32(&self.encounter_root)
            .hash32(&self.supply_root)
            .finish()
    }

    pub fn world_root(&self) -> Hash32 {
        protocol_hash(DOMAIN_WORLD_V1, &self.encode())
    }

    /// The settled artefact's `supply_commitment`; §7 pins it equal to `supply_root`.
    pub const fn supply_commitment(&self) -> Hash32 {
        self.supply_root
    }

    pub const fn field(&self, tag: Tag) -> &Hash32 {
        match tag {
            Tag::Subject => &self.subject_root,
            Tag::Blockmon => &self.blockmon_root,
            Tag::Encounter => &self.encounter_root,
            Tag::Supply => &self.supply_root,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Malformed {
    SiblingCount(usize),
    KeyLength(usize),
    UnassignedTag(u8),
    SupplyKeyNotZero,
    RecordEncoding(DecodeError),
    IdentifierMismatch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Invalid {
    RootMismatch,
    RootNotAtAssignedPosition,
    OldValueDoesNotAnchor,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProofError {
    Malformed(Malformed),
    Invalid(Invalid),
}

/// One domain value at a key: encoded record bytes, or `None` for absence.
pub type Value<'a> = Option<&'a [u8]>;

/// Applies the malformedness rules of §7 to one value at `(tag, key)` and returns its level-0
/// commitment.
fn level_zero(tag: Tag, key: &Hash32, value: Value<'_>) -> Result<Hash32, Malformed> {
    check_record(tag, key, value)?;
    Ok(value.map_or_else(|| empty(0), |bytes| leaf(tag, key, bytes)))
}

/// Record decoding and identifier binding, with no hash.
fn check_record(tag: Tag, key: &Hash32, value: Value<'_>) -> Result<(), Malformed> {
    let Some(bytes) = value else {
        return Ok(());
    };
    let carried = match tag {
        Tag::Subject => {
            if !bytes.is_empty() {
                return Err(Malformed::RecordEncoding(DecodeError::TrailingBytes(
                    bytes.len(),
                )));
            }
            None
        }
        Tag::Blockmon => Some(
            BlockmonRecord::decode(bytes)
                .map_err(Malformed::RecordEncoding)?
                .creature_id,
        ),
        Tag::Encounter => Some(
            PermitRecord::decode(bytes)
                .map_err(Malformed::RecordEncoding)?
                .permit_id,
        ),
        Tag::Supply => {
            Supply::decode(bytes).map_err(Malformed::RecordEncoding)?;
            None
        }
    };
    if carried.is_some_and(|id| id != *key) {
        return Err(Malformed::IdentifierMismatch);
    }
    Ok(())
}

fn check_key(tag: u8, key: &[u8]) -> Result<(Tag, Hash32), Malformed> {
    let key: Hash32 = key
        .try_into()
        .map_err(|_| Malformed::KeyLength(key.len()))?;
    let tag = Tag::from_u8(tag).ok_or(Malformed::UnassignedTag(tag))?;
    if tag == Tag::Supply && key != ZERO32 {
        return Err(Malformed::SupplyKeyNotZero);
    }
    Ok((tag, key))
}

fn check_shape(tag: u8, key: &[u8], siblings: &[Hash32]) -> Result<(Tag, Hash32), Malformed> {
    if siblings.len() != DEPTH {
        return Err(Malformed::SiblingCount(siblings.len()));
    }
    check_key(tag, key)
}

/// The malformed classes of §7 other than the sibling count, applied to an update's old and new
/// values, then their level-0 commitments. Costs at most two leaf hashes and climbs nothing.
pub fn admitted_level_zero(
    tag: Tag,
    key: &Hash32,
    old: Value<'_>,
    new: Value<'_>,
) -> Result<(Hash32, Hash32), Malformed> {
    let (tag, key) = check_key(tag as u8, key)?;
    check_record(tag, &key, old)?;
    check_record(tag, &key, new)?;
    Ok((level_zero(tag, &key, old)?, level_zero(tag, &key, new)?))
}

/// A logical proof: `(tag, key, record or absence, 256 siblings leaf to root)`.
pub struct Proof<'a> {
    pub tag: u8,
    pub key: &'a [u8],
    pub value: Value<'a>,
    pub siblings: &'a [Hash32],
}

pub fn verify_proof(
    proof: &Proof<'_>,
    claimed_domain_root: &Hash32,
    world: &WorldCommitmentV1,
) -> Result<(), ProofError> {
    let (tag, key) =
        check_shape(proof.tag, proof.key, proof.siblings).map_err(ProofError::Malformed)?;
    let lz = level_zero(tag, &key, proof.value).map_err(ProofError::Malformed)?;
    if root_from(&key, &lz, proof.siblings) != *claimed_domain_root {
        return Err(ProofError::Invalid(Invalid::RootMismatch));
    }
    if world.field(tag) != claimed_domain_root {
        return Err(ProofError::Invalid(Invalid::RootNotAtAssignedPosition));
    }
    Ok(())
}

/// `(tag, key, old value, new value, siblings, claimed pre-state domain root)`.
pub struct Update<'a> {
    pub tag: u8,
    pub key: &'a [u8],
    pub old: Value<'a>,
    pub new: Value<'a>,
    pub siblings: &'a [Hash32],
    pub claimed_pre_root: Hash32,
}

/// Returns the post-state domain root.
pub fn apply_update(update: &Update<'_>) -> Result<Hash32, ProofError> {
    let (tag, key) =
        check_shape(update.tag, update.key, update.siblings).map_err(ProofError::Malformed)?;
    let old = level_zero(tag, &key, update.old).map_err(ProofError::Malformed)?;
    let new = level_zero(tag, &key, update.new).map_err(ProofError::Malformed)?;
    if root_from(&key, &old, update.siblings) != update.claimed_pre_root {
        return Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor));
    }
    Ok(root_from(&key, &new, update.siblings))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoding::is_valid_domain;

    fn key(first: u8, last: u8) -> Hash32 {
        let mut k = [0u8; 32];
        k[0] = first;
        k[31] = last;
        k
    }

    fn subject_leaves(keys: &[Hash32]) -> Vec<(Hash32, Hash32)> {
        let mut v: Vec<_> = keys
            .iter()
            .map(|k| (*k, leaf(Tag::Subject, k, &[])))
            .collect();
        v.sort_unstable();
        v
    }

    #[test]
    fn domains_are_well_formed() {
        for d in [
            DOMAIN_SMT_LEAF,
            DOMAIN_SMT_NODE,
            DOMAIN_SMT_EMPTY,
            DOMAIN_WORLD_V1,
        ] {
            assert!(is_valid_domain(d), "{d}");
        }
    }

    #[test]
    fn empty_ladder() {
        assert_eq!(empty(0), protocol_hash("blockmon/smt-empty/v0", b""));
        for d in 0..DEPTH {
            let mut pre = empty(d).to_vec();
            pre.extend_from_slice(&empty(d));
            assert_eq!(empty(d + 1), protocol_hash("blockmon/smt-node/v0", &pre));
        }
        assert_eq!(root(&[]), empty(DEPTH));
        let distinct: std::collections::BTreeSet<_> = (0..=DEPTH).map(empty).collect();
        assert_eq!(distinct.len(), DEPTH + 1);
    }

    #[test]
    fn subject_leaf_preimage_ends_at_the_key() {
        let k = key(0xaa, 0xbb);
        let mut pre = vec![1u8];
        pre.extend_from_slice(&k);
        assert_eq!(pre.len(), 33);
        assert_eq!(
            leaf(Tag::Subject, &k, &[]),
            protocol_hash("blockmon/smt-leaf/v0", &pre)
        );
        let mut with_prefix = pre.clone();
        with_prefix.extend_from_slice(&[0, 0, 0, 0]);
        assert_ne!(
            leaf(Tag::Subject, &k, &[]),
            protocol_hash("blockmon/smt-leaf/v0", &with_prefix)
        );
    }

    #[test]
    fn bit_order_is_msb_first_within_each_byte() {
        let mut k = [0u8; 32];
        k[0] = 0b1000_0000;
        k[1] = 0b0000_0001;
        assert_eq!(bit(&k, 0), 1);
        assert_eq!(bit(&k, 1), 0);
        assert_eq!(bit(&k, 15), 1);
        assert_eq!(bit(&k, 8), 0);
        let mut last = [0u8; 32];
        last[31] = 1;
        assert_eq!(bit(&last, 255), 1);
    }

    #[test]
    fn single_leaf_climbs_through_every_level_without_collapse() {
        let k = key(0x80, 0x01);
        let l = leaf(Tag::Subject, &k, &[]);
        let mut cur = l;
        for level in 0..DEPTH {
            let i = DEPTH - 1 - level;
            cur = if bit(&k, i) == 0 {
                node(&cur, &empty(level))
            } else {
                node(&empty(level), &cur)
            };
        }
        assert_eq!(root(&[(k, l)]), cur);
        let top_right = node(&empty(DEPTH - 1), &subtree(DEPTH - 1, &[(k, l)]));
        assert_eq!(root(&[(k, l)]), top_right);
    }

    #[test]
    fn two_leaves_splitting_at_the_last_bit() {
        let items = subject_leaves(&[key(0, 0), key(0, 1)]);
        let mut cur = node(&items[0].1, &items[1].1);
        for level in 1..DEPTH {
            cur = node(&cur, &empty(level));
        }
        assert_eq!(root(&items), cur);
    }

    #[test]
    fn proofs_of_presence_and_absence_verify() {
        let keys = [key(0x00, 1), key(0x40, 2), key(0x41, 3), key(0xff, 4)];
        let items = subject_leaves(&keys);
        let r = root(&items);
        let wc = WorldCommitmentV1 {
            subject_root: r,
            blockmon_root: empty(DEPTH),
            encounter_root: empty(DEPTH),
            supply_root: empty(DEPTH),
        };
        for k in &keys {
            let sib = siblings(&items, k);
            let p = Proof {
                tag: 1,
                key: k,
                value: Some(&[]),
                siblings: &sib,
            };
            assert_eq!(verify_proof(&p, &r, &wc), Ok(()));
            let absent = Proof { value: None, ..p };
            assert_eq!(
                verify_proof(&absent, &r, &wc),
                Err(ProofError::Invalid(Invalid::RootMismatch))
            );
        }
        let missing = key(0x41, 9);
        let sib = siblings(&items, &missing);
        let p = Proof {
            tag: 1,
            key: &missing,
            value: None,
            siblings: &sib,
        };
        assert_eq!(verify_proof(&p, &r, &wc), Ok(()));
        let wrong_field = Proof {
            tag: 2,
            key: &missing,
            value: None,
            siblings: &sib,
        };
        assert_eq!(
            verify_proof(&wrong_field, &r, &wc),
            Err(ProofError::Invalid(Invalid::RootNotAtAssignedPosition))
        );
    }

    #[test]
    fn malformed_classes() {
        let r = empty(DEPTH);
        let wc = WorldCommitmentV1 {
            subject_root: r,
            blockmon_root: r,
            encounter_root: r,
            supply_root: r,
        };
        let sib: Vec<Hash32> = (0..DEPTH).map(empty).collect();
        let k = key(1, 1);
        let m = |p: &Proof<'_>| match verify_proof(p, &r, &wc) {
            Err(ProofError::Malformed(m)) => Some(m),
            _ => None,
        };
        let base = Proof {
            tag: 1,
            key: &k,
            value: None,
            siblings: &sib,
        };
        assert_eq!(verify_proof(&base, &r, &wc), Ok(()));
        assert_eq!(
            m(&Proof {
                siblings: &sib[..255],
                ..base
            }),
            Some(Malformed::SiblingCount(255))
        );
        assert_eq!(
            m(&Proof {
                key: &k[..31],
                ..base
            }),
            Some(Malformed::KeyLength(31))
        );
        assert_eq!(
            m(&Proof { tag: 0, ..base }),
            Some(Malformed::UnassignedTag(0))
        );
        assert_eq!(
            m(&Proof { tag: 5, ..base }),
            Some(Malformed::UnassignedTag(5))
        );
        assert_eq!(
            m(&Proof { tag: 4, ..base }),
            Some(Malformed::SupplyKeyNotZero)
        );
        assert_eq!(
            m(&Proof {
                value: Some(&[0]),
                ..base
            }),
            Some(Malformed::RecordEncoding(DecodeError::TrailingBytes(1)))
        );
        let bm = BlockmonRecord {
            creature_id: key(2, 2),
            owner: k,
            origin_permit: k,
        }
        .encode();
        assert_eq!(
            m(&Proof {
                tag: 2,
                value: Some(&bm),
                ..base
            }),
            Some(Malformed::IdentifierMismatch)
        );
        assert_eq!(
            m(&Proof {
                tag: 2,
                value: Some(&bm[..95]),
                ..base
            }),
            Some(Malformed::RecordEncoding(DecodeError::Truncated))
        );
        let mut permit = PermitRecord {
            permit_id: k,
            subject: k,
            encounter_class: 1,
            expiry_position: 0,
            status: 1,
        }
        .encode();
        permit[73] = 0;
        assert_eq!(
            m(&Proof {
                tag: 3,
                value: Some(&permit),
                ..base
            }),
            Some(Malformed::RecordEncoding(DecodeError::UnassignedEnum(0)))
        );
    }

    #[test]
    fn update_matches_full_derivation_for_insert_modify_delete() {
        let keys = [key(0x10, 1), key(0x11, 2), key(0x90, 3)];
        let bm = |k: &Hash32, o: u8| BlockmonRecord {
            creature_id: *k,
            owner: [o; 32],
            origin_permit: [o; 32],
        };
        let leaves = |recs: &[BlockmonRecord]| {
            let mut v: Vec<_> = recs
                .iter()
                .map(|r| {
                    (
                        r.creature_id,
                        leaf(Tag::Blockmon, &r.creature_id, &r.encode()),
                    )
                })
                .collect();
            v.sort_unstable();
            v
        };
        let pre = vec![bm(&keys[0], 1), bm(&keys[2], 1)];
        let pre_leaves = leaves(&pre);
        let pre_root = root(&pre_leaves);

        let ins = bm(&keys[1], 7);
        let enc = ins.encode();
        let sib = siblings(&pre_leaves, &keys[1]);
        let u = Update {
            tag: 2,
            key: &keys[1],
            old: None,
            new: Some(&enc),
            siblings: &sib,
            claimed_pre_root: pre_root,
        };
        let post = vec![pre[0].clone(), ins, pre[1].clone()];
        assert_eq!(apply_update(&u), Ok(root(&leaves(&post))));

        let modified = bm(&keys[0], 9);
        let (old, new) = (pre[0].encode(), modified.encode());
        let sib = siblings(&pre_leaves, &keys[0]);
        let u = Update {
            tag: 2,
            key: &keys[0],
            old: Some(&old),
            new: Some(&new),
            siblings: &sib,
            claimed_pre_root: pre_root,
        };
        assert_eq!(
            apply_update(&u),
            Ok(root(&leaves(&[modified, pre[1].clone()])))
        );

        let u = Update {
            tag: 2,
            key: &keys[0],
            old: Some(&old),
            new: None,
            siblings: &sib,
            claimed_pre_root: pre_root,
        };
        assert_eq!(apply_update(&u), Ok(root(&leaves(&[pre[1].clone()]))));

        let u = Update {
            tag: 2,
            key: &keys[0],
            old: None,
            new: Some(&new),
            siblings: &sib,
            claimed_pre_root: pre_root,
        };
        assert_eq!(
            apply_update(&u),
            Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor))
        );
    }

    #[test]
    fn store_agrees_with_the_walk_for_keys_sharing_255_bits() {
        let mut keys = vec![key(0x30, 0x30), key(0x30, 0x31), key(0x31, 0), key(0xc0, 7)];
        keys.sort_unstable();
        let mut items = subject_leaves(&keys);
        let mut store = Store::of(&items);
        assert_eq!(store.root(), root(&items));
        for k in keys.iter().chain(&[key(0x30, 0x32), key(0xff, 0xff)]) {
            assert_eq!(store.siblings(k), siblings(&items, k));
        }
        let fresh = key(0x30, 0x32);
        let lz = leaf(Tag::Subject, &fresh, &[]);
        let inserted = store.set(&fresh, lz);
        items.push((fresh, lz));
        items.sort_unstable();
        assert_eq!(inserted, root(&items));
        let deleted = store.set(&keys[1], empty(0));
        items.retain(|(k, _)| *k != keys[1]);
        assert_eq!(deleted, root(&items));
        assert_eq!(store.siblings(&keys[0]), siblings(&items, &keys[0]));
        for k in &keys {
            store.set(k, empty(0));
        }
        store.set(&fresh, empty(0));
        assert_eq!(store.root(), empty(DEPTH));
        assert!(store.nodes.is_empty());
    }

    #[test]
    fn batch_root_is_order_independent() {
        let keys = [key(0x01, 1), key(0x02, 2), key(0x81, 3), key(0x82, 4)];
        let start = subject_leaves(&keys[..1]);
        let apply = |order: &[usize]| {
            let mut cur = start.clone();
            for &i in order {
                let sib = siblings(&cur, &keys[i]);
                let u = Update {
                    tag: 1,
                    key: &keys[i],
                    old: None,
                    new: Some(&[]),
                    siblings: &sib,
                    claimed_pre_root: root(&cur),
                };
                assert!(apply_update(&u).is_ok());
                cur.push((keys[i], leaf(Tag::Subject, &keys[i], &[])));
                cur.sort_unstable();
            }
            root(&cur)
        };
        let all = root(&subject_leaves(&keys));
        for order in [
            [1, 2, 3],
            [1, 3, 2],
            [2, 1, 3],
            [2, 3, 1],
            [3, 1, 2],
            [3, 2, 1],
        ] {
            assert_eq!(apply(&order), all);
        }
    }

    #[test]
    fn each_batch_update_anchors_in_the_root_its_predecessor_left() {
        let (a, b) = (key(0x10, 1), key(0x10, 2));
        let start = subject_leaves(&[key(0x90, 9)]);
        let insert = |k: &Hash32, sib: &[Hash32], pre: Hash32| {
            apply_update(&Update {
                tag: 1,
                key: k,
                old: None,
                new: Some(&[]),
                siblings: sib,
                claimed_pre_root: pre,
            })
        };
        let r0 = root(&start);
        let (sib_a, stale_b) = (siblings(&start, &a), siblings(&start, &b));
        let r1 = insert(&a, &sib_a, r0).unwrap_or_else(|e| panic!("{e:?}"));
        let mut after_a = start;
        after_a.push((a, leaf(Tag::Subject, &a, &[])));
        after_a.sort_unstable();
        assert_eq!(r1, root(&after_a));
        let fresh_b = siblings(&after_a, &b);
        assert_ne!(fresh_b, stale_b);
        let full = root(&subject_leaves(&[a, b, key(0x90, 9)]));
        assert_eq!(insert(&b, &fresh_b, r1), Ok(full));
        assert_eq!(
            insert(&b, &stale_b, r1),
            Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor))
        );
        assert_ne!(insert(&b, &stale_b, r0), Ok(full));
    }

    #[test]
    fn a_refused_update_climbs_only_its_old_value() {
        let k = key(0x10, 1);
        let rec = BlockmonRecord {
            creature_id: k,
            owner: k,
            origin_permit: k,
        }
        .encode();
        let sib: Vec<Hash32> = (0..DEPTH).map(empty).collect();
        let u = Update {
            tag: 2,
            key: &k,
            old: Some(&rec),
            new: Some(&rec),
            siblings: &sib,
            claimed_pre_root: empty(DEPTH),
        };
        let before = crate::encoding::HASHES.with(std::cell::Cell::get);
        let refused = apply_update(&u);
        let cost = crate::encoding::HASHES.with(std::cell::Cell::get) - before;
        assert_eq!(
            refused,
            Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor))
        );
        assert_eq!(cost, 2 + DEPTH);
    }

    #[test]
    fn same_key_updates_compose_sequentially_to_their_final_value() {
        let k = key(0x10, 1);
        let rec = |o: u8| {
            BlockmonRecord {
                creature_id: k,
                owner: [o; 32],
                origin_permit: [o; 32],
            }
            .encode()
        };
        let (a, b, c) = (rec(1), rec(2), rec(3));
        let start = vec![(key(0x90, 9), leaf(Tag::Blockmon, &key(0x90, 9), &rec(9)))];
        let sib = siblings(&start, &k);
        let step = |old: Option<&[u8]>, new: Option<&[u8]>, pre: Hash32| {
            apply_update(&Update {
                tag: 2,
                key: &k,
                old,
                new,
                siblings: &sib,
                claimed_pre_root: pre,
            })
        };
        let r0 = root(&start);
        let r1 = step(None, Some(&a), r0);
        let r2 = r1.and_then(|r| step(Some(&a), Some(&b), r));
        let r3 = r2.clone().and_then(|r| step(Some(&b), Some(&c), r));
        assert_eq!(r3, step(None, Some(&c), r0));
        assert_eq!(
            r2.and_then(|r| step(Some(&a), Some(&c), r)),
            Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor))
        );
    }

    #[test]
    fn an_anchored_update_costs_two_leaf_hashes_and_two_climbs() {
        let k = key(0x10, 1);
        let rec = |o: u8| {
            BlockmonRecord {
                creature_id: k,
                owner: [o; 32],
                origin_permit: [o; 32],
            }
            .encode()
        };
        let (old, new) = (rec(1), rec(2));
        let items = vec![(k, leaf(Tag::Blockmon, &k, &old))];
        let sib = siblings(&items, &k);
        let u = Update {
            tag: 2,
            key: &k,
            old: Some(&old),
            new: Some(&new),
            siblings: &sib,
            claimed_pre_root: root(&items),
        };
        let before = crate::encoding::HASHES.with(std::cell::Cell::get);
        let post = apply_update(&u);
        let cost = crate::encoding::HASHES.with(std::cell::Cell::get) - before;
        assert_eq!(post, Ok(root(&[(k, leaf(Tag::Blockmon, &k, &new))])));
        assert_eq!(cost, 2 + 2 * DEPTH);
    }

    #[test]
    fn malformed_takes_precedence_over_an_unanchored_old_value() {
        let k = key(0x10, 1);
        let sib: Vec<Hash32> = (0..DEPTH).map(empty).collect();
        let record = |id: Hash32| {
            BlockmonRecord {
                creature_id: id,
                owner: k,
                origin_permit: k,
            }
            .encode()
        };
        let (good, misbound) = (record(k), record(key(0x20, 2)));
        let unanchored = Update {
            tag: 2,
            key: &k,
            old: Some(&good),
            new: Some(&good),
            siblings: &sib,
            claimed_pre_root: empty(DEPTH),
        };
        assert_eq!(
            apply_update(&unanchored),
            Err(ProofError::Invalid(Invalid::OldValueDoesNotAnchor))
        );
        let cases = [
            (
                Update {
                    new: Some(&misbound),
                    ..unanchored
                },
                Malformed::IdentifierMismatch,
            ),
            (
                Update {
                    old: Some(&good[..95]),
                    ..unanchored
                },
                Malformed::RecordEncoding(DecodeError::Truncated),
            ),
            (
                Update {
                    siblings: &sib[1..],
                    ..unanchored
                },
                Malformed::SiblingCount(DEPTH - 1),
            ),
            (
                Update {
                    tag: 4,
                    ..unanchored
                },
                Malformed::SupplyKeyNotZero,
            ),
        ];
        for (u, m) in cases {
            assert_eq!(apply_update(&u), Err(ProofError::Malformed(m)));
        }
    }

    #[test]
    fn admission_applies_the_key_and_record_classes_without_climbing() {
        let (k, e0) = (key(0, 1), empty(0));
        let before = crate::encoding::HASHES.with(std::cell::Cell::get);
        let refused = admitted_level_zero(Tag::Supply, &k, None, None);
        let bad_old = admitted_level_zero(Tag::Subject, &k, Some(&[0]), None);
        let deleted = admitted_level_zero(Tag::Subject, &k, Some(&[]), None);
        let inserted = admitted_level_zero(Tag::Subject, &k, None, Some(&[]));
        let cost = crate::encoding::HASHES.with(std::cell::Cell::get) - before;
        assert_eq!(refused, Err(Malformed::SupplyKeyNotZero));
        assert_eq!(
            bad_old,
            Err(Malformed::RecordEncoding(DecodeError::TrailingBytes(1)))
        );
        let l = leaf(Tag::Subject, &k, &[]);
        assert_eq!(deleted, Ok((l, e0)));
        assert_eq!(inserted, Ok((e0, l)));
        assert_eq!(cost, 2);
    }
}
