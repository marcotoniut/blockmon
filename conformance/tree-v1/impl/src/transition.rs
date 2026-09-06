//! CE §7 Cost, read as behaviour rather than as an estimate: what a transition does to the
//! commitment, and how many hashes that costs. The counts here are observed at the
//! `protocol_hash` call site. A count this crate derives from a formula, compared against the
//! same formula, would establish nothing.

use crate::hash::{Hash32, hash_calls, hash_calls_reset};
use crate::record::Tag;
use crate::tree::{DomainState, EmptyLadder};
use crate::world::WorldCommitmentV1;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Cost {
    /// Counted, never computed from the touched-key count.
    pub hashes: u64,
    pub world_recomputations: usize,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Outcome {
    pub commitment: WorldCommitmentV1,
    pub world_root: Hash32,
    pub cost: Cost,
}

/// "A state-changing transition costs [one leaf hash and 256 node hashes] per key touched,
/// plus one `blockmon/world/v1` recomputation after its authenticated-key updates."
pub fn accepted(
    input: &WorldCommitmentV1,
    touched: &[(Tag, &DomainState)],
    ladder: &EmptyLadder,
) -> Outcome {
    let mut commitment = *input;
    hash_calls_reset();
    for (tag, state) in touched {
        commitment.set_root_for(*tag, state.root(ladder));
    }
    let world_root = commitment.world_root();
    Outcome {
        commitment,
        world_root,
        cost: Cost {
            hashes: hash_calls(),
            world_recomputations: 1,
        },
    }
}

/// "A rejected transition returns the input commitment unchanged and incurs no
/// state-recomputation hash." CE §6 adds that it "returns the input state byte-identical".
pub fn rejected(input: &WorldCommitmentV1, prev_world_root: Hash32) -> Outcome {
    hash_calls_reset();
    Outcome {
        commitment: *input,
        world_root: prev_world_root,
        cost: Cost {
            hashes: hash_calls(),
            world_recomputations: 0,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{Cost, accepted, rejected};
    use crate::hash::{hash_calls, hash_calls_reset};
    use crate::record::{Record, Tag};
    use crate::tree::{DEPTH, DomainState, EmptyLadder, climb, leaf};
    use crate::world::WorldCommitmentV1;

    fn empty_world(ladder: &EmptyLadder) -> WorldCommitmentV1 {
        let mut input = WorldCommitmentV1::default();
        for tag in Tag::ALL {
            input.set_root_for(tag, DomainState::empty(tag).root(ladder));
        }
        input
    }

    #[test]
    fn a_rejected_transition_recomputes_nothing_and_returns_the_input_commitment() {
        let ladder = EmptyLadder::compute();
        let input = empty_world(&ladder);
        let before = input.world_root();

        let outcome = rejected(&input, before);
        assert_eq!(outcome.commitment, input);
        assert_eq!(outcome.world_root, before);
        assert_eq!(outcome.cost, Cost::default());
        assert_eq!(outcome.cost.hashes, 0);
    }

    #[test]
    fn an_accepted_single_key_transition_costs_one_leaf_and_256_nodes_plus_one_world_hash() {
        let ladder = EmptyLadder::compute();
        let input = empty_world(&ladder);
        let before = input.world_root();

        let mut subjects = DomainState::empty(Tag::Subject);
        subjects.insert(&[7u8; 32], &[]).expect("unit record");
        let outcome = accepted(&input, &[(Tag::Subject, &subjects)], &ladder);

        // A single-key domain's full derivation is that key's climb, so the measured
        // total is the per-key figure plus the one world recomputation.
        assert_eq!(
            outcome.cost,
            Cost {
                hashes: 1 + DEPTH as u64 + 1,
                world_recomputations: 1
            }
        );
        assert_ne!(outcome.world_root, before);
        assert_eq!(outcome.commitment.blockmon_root, input.blockmon_root);
    }

    /// CE §7: "Committing one key costs one leaf hash and 256 node hashes, independent of
    /// domain size." Measured at three occupancies, since a figure that only holds at one is
    /// not the claim.
    #[test]
    fn the_per_key_recomputation_holds_at_every_occupancy() {
        let ladder = EmptyLadder::compute();
        let key = [0u8; 32];
        let mut counted = Vec::new();

        for n in [1usize, 8, 257] {
            let mut state = DomainState::empty(Tag::Subject);
            for i in 0..n {
                let mut other = [0u8; 32];
                other[0] = u8::try_from(i % 256).expect("byte");
                other[1] = u8::try_from(i / 256).expect("byte");
                state.insert(&other, &[]).expect("unit record");
            }
            let siblings = state.siblings(&ladder, &key);

            hash_calls_reset();
            let root = climb(&key, leaf(Tag::Subject, &key, &Record::Subject), &siblings);
            counted.push(hash_calls());

            assert_eq!(root, state.root(&ladder), "occupancy {n}");
        }

        assert!(
            counted.iter().all(|&c| c == 1 + DEPTH as u64),
            "per-key recomputation moved with occupancy: {counted:?}"
        );
    }
}
