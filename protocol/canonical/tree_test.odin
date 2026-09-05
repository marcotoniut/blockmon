package canonical

import "core:testing"

KEY_A :: [32]byte{0 ..= 31 = 0xA1}
KEY_B :: [32]byte{0 ..= 31 = 0xB2}

update_fixture :: proc() -> (entries: [2]Tree_Entry, siblings: [TREE_DEPTH][32]byte, root: [32]byte) {
	tree_ensure_init()
	entries = [2]Tree_Entry {
		{key = KEY_A, record = transmute([]byte)string("old")},
		{key = KEY_B, record = transmute([]byte)string("other")},
	}
	root = domain_root(.Blockmon, entries[:])
	tree_siblings(.Blockmon, entries[:], KEY_A, &siblings)
	return
}

// The positive control: the bounded path must reach the root the full
// derivation reaches for the same post-state.
@(test)
update_agrees_with_full_derivation :: proc(t: ^testing.T) {
	entries, siblings, root := update_fixture()
	new_record := transmute([]byte)string("new")

	got, err := apply_update(
		.Blockmon,
		KEY_A,
		entries[0].record,
		true,
		new_record,
		true,
		siblings[:],
		root,
	)
	testing.expect_value(t, err, Update_Error.None)

	after := entries
	after[0].record = new_record
	testing.expect_value(t, got, domain_root(.Blockmon, after[:]))
}

// The anchoring is what keeps apply_update a verifier rather than a fast root
// constructor: a proof that does not open the claimed root must be refused, not
// climbed. Nothing in the vector tiers exercises this, since they record only
// accepted updates.
@(test)
update_refuses_a_wrong_claimed_root :: proc(t: ^testing.T) {
	entries, siblings, root := update_fixture()
	wrong := root
	wrong[31] ~= 0x01

	_, err := apply_update(
		.Blockmon,
		KEY_A,
		entries[0].record,
		true,
		transmute([]byte)string("new"),
		true,
		siblings[:],
		wrong,
	)
	testing.expect_value(t, err, Update_Error.Old_Root_Mismatch)
}

// Claiming the key was absent when the root commits a record for it is the same
// failure, reached from the other side.
@(test)
update_refuses_a_wrong_old_value :: proc(t: ^testing.T) {
	entries, siblings, root := update_fixture()

	_, err := apply_update(
		.Blockmon,
		KEY_A,
		entries[0].record,
		false,
		transmute([]byte)string("new"),
		true,
		siblings[:],
		root,
	)
	testing.expect_value(t, err, Update_Error.Old_Root_Mismatch)
}

// §7 Malformed: a sibling count other than TREE_DEPTH, on both sides of it.
@(test)
update_refuses_a_malformed_proof :: proc(t: ^testing.T) {
	entries, siblings, root := update_fixture()
	long := make([][32]byte, TREE_DEPTH + 1)
	defer delete(long)
	copy(long, siblings[:])

	bad := [][][32]byte{siblings[:TREE_DEPTH - 1], long}
	for s in bad {
		_, err := apply_update(
			.Blockmon,
			KEY_A,
			entries[0].record,
			true,
			transmute([]byte)string("new"),
			true,
			s,
			root,
		)
		testing.expect_value(t, err, Update_Error.Malformed_Proof)
	}
}
