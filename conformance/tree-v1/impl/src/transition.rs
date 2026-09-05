//! CE §7 Cost, read as behaviour rather than as an estimate: what a transition does to the
//! commitment, and how many hashes that costs.

use crate::hash::Hash32;
use crate::record::Tag;
use crate::tree::{DEPTH, DomainState, EmptyLadder};
use crate::world::WorldCommitmentV1;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Cost {
    pub leaf_hashes: usize,
    pub node_hashes: usize,
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
    for (tag, state) in touched {
        commitment.set_root_for(*tag, state.root(ladder));
    }
    Outcome {
        commitment,
        world_root: commitment.world_root(),
        cost: Cost {
            leaf_hashes: touched.len(),
            node_hashes: touched.len() * DEPTH,
            world_recomputations: 1,
        },
    }
}

/// "A rejected transition returns the input commitment unchanged and incurs no
/// state-recomputation hash." CE §6 adds that it "returns the input state byte-identical".
pub fn rejected(input: &WorldCommitmentV1, prev_world_root: Hash32) -> Outcome {
    Outcome {
        commitment: *input,
        world_root: prev_world_root,
        cost: Cost::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::{Cost, accepted, rejected};
    use crate::record::Tag;
    use crate::tree::{DEPTH, DomainState, EmptyLadder};
    use crate::world::WorldCommitmentV1;

    #[test]
    fn a_rejected_transition_recomputes_nothing_and_returns_the_input_commitment() {
        let ladder = EmptyLadder::compute();
        let mut input = WorldCommitmentV1::default();
        for tag in Tag::ALL {
            input.set_root_for(tag, DomainState::empty(tag).root(&ladder));
        }
        let before = input.world_root();

        let outcome = rejected(&input, before);
        assert_eq!(outcome.commitment, input);
        assert_eq!(outcome.world_root, before);
        assert_eq!(outcome.cost, Cost::default());
        assert_eq!(outcome.cost.world_recomputations, 0);
    }

    #[test]
    fn an_accepted_single_key_transition_costs_one_leaf_and_256_nodes_plus_one_world_hash() {
        let ladder = EmptyLadder::compute();
        let mut input = WorldCommitmentV1::default();
        for tag in Tag::ALL {
            input.set_root_for(tag, DomainState::empty(tag).root(&ladder));
        }
        let before = input.world_root();

        let mut subjects = DomainState::empty(Tag::Subject);
        subjects.insert(&[7u8; 32], &[]).expect("unit record");
        let outcome = accepted(&input, &[(Tag::Subject, &subjects)], &ladder);

        assert_eq!(
            outcome.cost,
            Cost {
                leaf_hashes: 1,
                node_hashes: DEPTH,
                world_recomputations: 1
            }
        );
        assert_ne!(outcome.world_root, before);
        assert_eq!(outcome.commitment.blockmon_root, input.blockmon_root);
    }
}
