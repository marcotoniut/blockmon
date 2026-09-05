//! CE §7 world commitment. Field set and order are constitutional; the domain-to-field
//! mapping is by field name, never by the tag's numeric value.

use crate::hash::{Hash32, WORLD_V1, protocol_hash};
use crate::record::Tag;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
#[expect(
    clippy::struct_field_names,
    reason = "CE §7 declares these four field names and their order as constitutional"
)]
pub struct WorldCommitmentV1 {
    pub subject_root: Hash32,
    pub blockmon_root: Hash32,
    pub encounter_root: Hash32,
    pub supply_root: Hash32,
}

impl WorldCommitmentV1 {
    pub fn encode(&self) -> [u8; 128] {
        let mut out = [0u8; 128];
        out[..32].copy_from_slice(&self.subject_root);
        out[32..64].copy_from_slice(&self.blockmon_root);
        out[64..96].copy_from_slice(&self.encounter_root);
        out[96..].copy_from_slice(&self.supply_root);
        out
    }

    pub fn world_root(&self) -> Hash32 {
        protocol_hash(WORLD_V1, &self.encode())
    }

    /// The assigned position of a domain's root.
    pub const fn root_for(&self, tag: Tag) -> Hash32 {
        match tag {
            Tag::Subject => self.subject_root,
            Tag::Blockmon => self.blockmon_root,
            Tag::Encounter => self.encounter_root,
            Tag::Supply => self.supply_root,
        }
    }

    pub const fn set_root_for(&mut self, tag: Tag, root: Hash32) {
        match tag {
            Tag::Subject => self.subject_root = root,
            Tag::Blockmon => self.blockmon_root = root,
            Tag::Encounter => self.encounter_root = root,
            Tag::Supply => self.supply_root = root,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::WorldCommitmentV1;
    use crate::record::Tag;

    fn distinct() -> WorldCommitmentV1 {
        WorldCommitmentV1 {
            subject_root: [1u8; 32],
            blockmon_root: [2u8; 32],
            encounter_root: [3u8; 32],
            supply_root: [4u8; 32],
        }
    }

    #[test]
    fn preimage_is_four_raw_roots_in_declared_order() {
        let encoded = distinct().encode();
        assert_eq!(encoded.len(), 128);
        assert_eq!(&encoded[..32], &[1u8; 32]);
        assert_eq!(&encoded[32..64], &[2u8; 32]);
        assert_eq!(&encoded[64..96], &[3u8; 32]);
        assert_eq!(&encoded[96..], &[4u8; 32]);
    }

    #[test]
    fn each_domain_reads_its_own_field() {
        let world = distinct();
        assert_eq!(world.root_for(Tag::Subject), [1u8; 32]);
        assert_eq!(world.root_for(Tag::Blockmon), [2u8; 32]);
        assert_eq!(world.root_for(Tag::Encounter), [3u8; 32]);
        assert_eq!(world.root_for(Tag::Supply), [4u8; 32]);
    }

    /// Field position is the only binding an empty domain root has, so permuting two
    /// roots must change `world_root`.
    #[test]
    fn permuting_two_roots_changes_the_world_root() {
        let world = distinct();
        let mut swapped = world;
        swapped.blockmon_root = world.encounter_root;
        swapped.encounter_root = world.blockmon_root;
        assert_ne!(world.world_root(), swapped.world_root());
    }
}
