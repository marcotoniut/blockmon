//! CE §7 Proofs: the logical proof, its verification, and the two rejection classes.

use core::fmt;

use crate::codec::DecodeError;
use crate::hash::Hash32;
use crate::record::{Record, Tag};
use crate::tree::{DEPTH, EmptyLadder, climb, leaf};
use crate::world::WorldCommitmentV1;

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Claim {
    /// Record bytes as carried, decoded by the verifier.
    Present(Vec<u8>),
    Absent,
}

/// `(tag, key, record or absence, 256 sibling commitments ordered leaf to root)`. No leaf
/// hash, no path data.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct LogicalProof {
    pub tag: u8,
    pub key: Vec<u8>,
    pub claim: Claim,
    pub siblings: Vec<Hash32>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Malformed {
    SiblingCount { actual: usize },
    KeyLength { actual: usize },
    UnassignedTag { tag: u8 },
    RecordDecode(DecodeError),
    SupplyKeyNotZero,
    IdentifierMismatch,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Invalid {
    RootMismatch,
    NotAtAssignedPosition,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Rejection {
    Malformed(Malformed),
    Invalid(Invalid),
}

impl Rejection {
    pub const fn class(self) -> &'static str {
        match self {
            Self::Malformed(_) => "malformed",
            Self::Invalid(_) => "invalid",
        }
    }
}

impl fmt::Display for Rejection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Malformed(reason) => match reason {
                Malformed::SiblingCount { actual } => {
                    write!(f, "malformed: sibling count {actual} != 256")
                }
                Malformed::KeyLength { actual } => {
                    write!(f, "malformed: key length {actual} != 32")
                }
                Malformed::UnassignedTag { tag } => write!(f, "malformed: unassigned tag {tag}"),
                Malformed::RecordDecode(e) => write!(f, "malformed: record bytes: {e}"),
                Malformed::SupplyKeyNotZero => {
                    write!(f, "malformed: supply key is not 32 zero bytes")
                }
                Malformed::IdentifierMismatch => {
                    write!(
                        f,
                        "malformed: record identifier does not equal the proof key"
                    )
                }
            },
            Self::Invalid(reason) => match reason {
                Invalid::RootMismatch => {
                    write!(f, "invalid: recomputed root != claimed domain root")
                }
                Invalid::NotAtAssignedPosition => {
                    write!(
                        f,
                        "invalid: claimed root not at its assigned position in world_root"
                    )
                }
            },
        }
    }
}

/// What a well-formed proof yields once its shape has been checked.
pub struct Accepted {
    pub tag: Tag,
    pub key: Hash32,
    pub record: Option<Record>,
    pub recomputed_root: Hash32,
}

/// The Malformed class, then the leaf and the climb.
///
/// CE §7 states that malformedness covers domain-local record semantics and not
/// only byte shape, and lists a record identifier that does not equal the proof
/// key. The binding is therefore checked here as well as in `tree::DomainState`,
/// rather than left to every producer having built valid state.
pub fn recompute(proof: &LogicalProof, ladder: &EmptyLadder) -> Result<Accepted, Rejection> {
    if proof.siblings.len() != DEPTH {
        return Err(Rejection::Malformed(Malformed::SiblingCount {
            actual: proof.siblings.len(),
        }));
    }
    let key: Hash32 = proof.key.as_slice().try_into().map_err(|_| {
        Rejection::Malformed(Malformed::KeyLength {
            actual: proof.key.len(),
        })
    })?;
    let tag = Tag::from_discriminant(proof.tag).ok_or(Rejection::Malformed(
        Malformed::UnassignedTag { tag: proof.tag },
    ))?;
    let record = match proof.claim {
        Claim::Present(ref bytes) => Some(
            Record::decode(tag, bytes)
                .map_err(|e| Rejection::Malformed(Malformed::RecordDecode(e)))?,
        ),
        Claim::Absent => None,
    };
    if matches!(tag, Tag::Supply) && key != [0u8; 32] {
        return Err(Rejection::Malformed(Malformed::SupplyKeyNotZero));
    }
    if let Some(ref r) = record
        && r.identifier().is_some_and(|id| id != key)
    {
        return Err(Rejection::Malformed(Malformed::IdentifierMismatch));
    }

    let level_zero = record
        .as_ref()
        .map_or_else(|| ladder.at(0), |r| leaf(tag, &key, r));
    let recomputed_root = climb(&key, level_zero, &proof.siblings);
    Ok(Accepted {
        tag,
        key,
        record,
        recomputed_root,
    })
}

/// Full CE §7 verification: recompute the root, compare with the claimed domain root, then
/// check that root at its assigned position in `WorldCommitmentV1`.
pub fn verify(
    proof: &LogicalProof,
    claimed_domain_root: &Hash32,
    world: &WorldCommitmentV1,
    ladder: &EmptyLadder,
) -> Result<(), Rejection> {
    let accepted = recompute(proof, ladder)?;
    if &accepted.recomputed_root != claimed_domain_root {
        return Err(Rejection::Invalid(Invalid::RootMismatch));
    }
    if &world.root_for(accepted.tag) != claimed_domain_root {
        return Err(Rejection::Invalid(Invalid::NotAtAssignedPosition));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Claim, Invalid, LogicalProof, Malformed, Rejection, recompute, verify};
    use crate::codec::DecodeError;
    use crate::hash::Hash32;
    use crate::record::Tag;
    use crate::tree::{DEPTH, DomainState, EmptyLadder};
    use crate::world::WorldCommitmentV1;

    struct Fixture {
        ladder: EmptyLadder,
        state: DomainState,
        world: WorldCommitmentV1,
        root: Hash32,
    }

    fn encounter_key(byte0: u8) -> Hash32 {
        let mut k = [0u8; 32];
        k[0] = byte0;
        k
    }

    fn permit_bytes(key: &Hash32) -> Vec<u8> {
        let mut bytes = vec![0u8; 74];
        bytes[..32].copy_from_slice(key);
        bytes[64] = 1;
        bytes[73] = 1;
        bytes
    }

    fn fixture() -> Fixture {
        let ladder = EmptyLadder::compute();
        let mut state = DomainState::empty(Tag::Encounter);
        for byte0 in [0x00u8, 0x37, 0xc1] {
            let key = encounter_key(byte0);
            state
                .insert(&key, &permit_bytes(&key))
                .expect("valid permit");
        }
        let root = state.root(&ladder);
        let mut world = WorldCommitmentV1::default();
        world.set_root_for(Tag::Encounter, root);
        Fixture {
            ladder,
            state,
            world,
            root,
        }
    }

    fn proof_for(f: &Fixture, key: &Hash32, claim: Claim) -> LogicalProof {
        LogicalProof {
            tag: Tag::Encounter.discriminant(),
            key: key.to_vec(),
            claim,
            siblings: f.state.siblings(&f.ladder, key),
        }
    }

    #[test]
    fn membership_and_absence_verify() {
        let f = fixture();
        let key = encounter_key(0x37);
        let present = proof_for(&f, &key, Claim::Present(permit_bytes(&key)));
        assert_eq!(verify(&present, &f.root, &f.world, &f.ladder), Ok(()));

        let missing = encounter_key(0x38);
        let absent = proof_for(&f, &missing, Claim::Absent);
        assert_eq!(verify(&absent, &f.root, &f.world, &f.ladder), Ok(()));
    }

    #[test]
    fn presence_claimed_for_an_absent_key_is_well_formed_but_invalid() {
        let f = fixture();
        let missing = encounter_key(0x38);
        let lie = proof_for(&f, &missing, Claim::Present(permit_bytes(&missing)));
        assert_eq!(
            verify(&lie, &f.root, &f.world, &f.ladder),
            Err(Rejection::Invalid(Invalid::RootMismatch))
        );
    }

    #[test]
    fn absence_claimed_for_a_present_key_is_well_formed_but_invalid() {
        let f = fixture();
        let key = encounter_key(0x37);
        let lie = proof_for(&f, &key, Claim::Absent);
        assert_eq!(
            verify(&lie, &f.root, &f.world, &f.ladder),
            Err(Rejection::Invalid(Invalid::RootMismatch))
        );
    }

    #[test]
    fn sibling_order_is_leaf_to_root_and_reversal_breaks_the_climb() {
        let f = fixture();
        let key = encounter_key(0x37);
        let mut reversed = proof_for(&f, &key, Claim::Present(permit_bytes(&key)));
        reversed.siblings.reverse();
        assert_ne!(
            recompute(&reversed, &f.ladder)
                .map(|a| a.recomputed_root)
                .ok(),
            Some(f.root)
        );
    }

    #[test]
    fn malformed_class_covers_exactly_the_listed_shapes() {
        let f = fixture();
        let key = encounter_key(0x37);
        let good = proof_for(&f, &key, Claim::Present(permit_bytes(&key)));

        let mut short_siblings = good.clone();
        short_siblings.siblings.pop();
        assert_eq!(
            recompute(&short_siblings, &f.ladder).err(),
            Some(Rejection::Malformed(Malformed::SiblingCount {
                actual: DEPTH - 1
            }))
        );

        let mut long_siblings = good.clone();
        long_siblings.siblings.push([0u8; 32]);
        assert_eq!(
            recompute(&long_siblings, &f.ladder).err(),
            Some(Rejection::Malformed(Malformed::SiblingCount {
                actual: DEPTH + 1
            }))
        );

        let mut short_key = good.clone();
        short_key.key.pop();
        assert_eq!(
            recompute(&short_key, &f.ladder).err(),
            Some(Rejection::Malformed(Malformed::KeyLength { actual: 31 }))
        );

        for tag in [0u8, 5, 255] {
            let mut bad_tag = good.clone();
            bad_tag.tag = tag;
            assert_eq!(
                recompute(&bad_tag, &f.ladder).err(),
                Some(Rejection::Malformed(Malformed::UnassignedTag { tag }))
            );
        }

        let mut wide_record = good.clone();
        wide_record.claim = Claim::Present({
            let mut bytes = permit_bytes(&key);
            bytes.push(0);
            bytes
        });
        assert_eq!(
            recompute(&wide_record, &f.ladder).err(),
            Some(Rejection::Malformed(Malformed::RecordDecode(
                DecodeError::TrailingBytes { extra: 1 }
            )))
        );

        let mut supply_proof = good.clone();
        supply_proof.tag = Tag::Supply.discriminant();
        supply_proof.claim = Claim::Present(vec![0u8; 40]);
        assert_eq!(
            recompute(&supply_proof, &f.ladder).err(),
            Some(Rejection::Malformed(Malformed::SupplyKeyNotZero))
        );

        // CE §7: a record identifier that does not equal the proof key. The
        // record is otherwise valid, so decoding succeeds and the binding is
        // what rejects it.
        let mut unbound = good;
        unbound.claim = Claim::Present(permit_bytes(&encounter_key(0x38)));
        assert_eq!(
            recompute(&unbound, &f.ladder).err(),
            Some(Rejection::Malformed(Malformed::IdentifierMismatch))
        );
    }

    #[test]
    fn a_root_at_the_wrong_world_position_is_invalid_not_malformed() {
        let f = fixture();
        let key = encounter_key(0x37);
        let proof = proof_for(&f, &key, Claim::Present(permit_bytes(&key)));

        let mut misplaced = WorldCommitmentV1::default();
        misplaced.set_root_for(Tag::Blockmon, f.root);
        assert_eq!(
            verify(&proof, &f.root, &misplaced, &f.ladder),
            Err(Rejection::Invalid(Invalid::NotAtAssignedPosition))
        );
    }

    /// CE §7 says the verifier computes the leaf itself, so a proof cannot smuggle one in:
    /// there is no field for it. Recorded here as an assertion about the type.
    #[test]
    fn logical_proof_carries_no_leaf_hash_or_path_data() {
        let f = fixture();
        let key = encounter_key(0x00);
        let proof = proof_for(&f, &key, Claim::Present(permit_bytes(&key)));
        let accepted = recompute(&proof, &f.ladder).expect("well formed");
        assert_eq!(accepted.recomputed_root, f.root);
        assert_eq!(accepted.key, key);
    }
}
