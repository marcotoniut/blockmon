package canonical

import "core:testing"

KEY_A :: [32]byte{0 ..= 31 = 0xA1}
KEY_B :: [32]byte{0 ..= 31 = 0xB2}

fill_key :: proc(b: byte) -> (out: [32]byte) {
	for i in 0 ..< 32 {
		out[i] = b
	}
	return
}

// A valid blockmon record at key: identifier head, then owner and origin bytes.
blockmon_record :: proc(buf: ^[BLOCKMON_RECORD_WIDTH]byte, key: [32]byte, fill: byte) -> []byte {
	k := key
	copy(buf[0:32], k[:])
	for i in 32 ..< BLOCKMON_RECORD_WIDTH {
		buf[i] = fill
	}
	return buf[:]
}

encounter_record :: proc(
	buf: ^[ENCOUNTER_RECORD_WIDTH]byte,
	key: [32]byte,
	fill: byte,
) -> []byte {
	k := key
	copy(buf[0:32], k[:])
	for i in 32 ..< 64 {
		buf[i] = fill
	}
	buf[64] = 1 // encounter_class COMMON
	for i in 65 ..< 73 {
		buf[i] = fill
	}
	buf[73] = 1 // status RESERVED
	return buf[:]
}

Update_Fixture :: struct {
	records:  [2][BLOCKMON_RECORD_WIDTH]byte,
	entries:  [2]Tree_Entry,
	siblings: [TREE_DEPTH][32]byte,
	root:     [32]byte,
}

update_fixture :: proc(f: ^Update_Fixture) {
	tree_ensure_init()
	f.entries[0] = Tree_Entry{key = KEY_A, record = blockmon_record(&f.records[0], KEY_A, 0x0D)}
	f.entries[1] = Tree_Entry{key = KEY_B, record = blockmon_record(&f.records[1], KEY_B, 0x0E)}
	f.root = domain_root(.Blockmon, f.entries[:])
	tree_siblings(.Blockmon, f.entries[:], KEY_A, &f.siblings)
}

// Positive control: same post-state, reached both ways.
@(test)
update_agrees_with_full_derivation :: proc(t: ^testing.T) {
	f: Update_Fixture
	update_fixture(&f)
	nb: [BLOCKMON_RECORD_WIDTH]byte
	new_record := blockmon_record(&nb, KEY_A, 0x0F)

	got, err := apply_update(
		.Blockmon,
		KEY_A,
		f.entries[0].record,
		true,
		new_record,
		true,
		f.siblings[:],
		f.root,
	)
	testing.expect_value(t, err, Update_Error.None)

	after := f.entries
	after[0].record = new_record
	testing.expect_value(t, got, domain_root(.Blockmon, after[:]))
}

// Anchoring makes this a verifier, not a root constructor. No vector tier
// uses it; they only record accepted updates.
@(test)
update_refuses_a_wrong_claimed_root :: proc(t: ^testing.T) {
	f: Update_Fixture
	update_fixture(&f)
	wrong := f.root
	wrong[31] ~= 0x01
	nb: [BLOCKMON_RECORD_WIDTH]byte

	_, err := apply_update(
		.Blockmon,
		KEY_A,
		f.entries[0].record,
		true,
		blockmon_record(&nb, KEY_A, 0x0F),
		true,
		f.siblings[:],
		wrong,
	)
	testing.expect_value(t, err, Update_Error.Old_Root_Mismatch)
}

// The mirror case: absence claimed for a committed key.
@(test)
update_refuses_a_wrong_old_value :: proc(t: ^testing.T) {
	f: Update_Fixture
	update_fixture(&f)
	nb: [BLOCKMON_RECORD_WIDTH]byte

	_, err := apply_update(
		.Blockmon,
		KEY_A,
		nil,
		false,
		blockmon_record(&nb, KEY_A, 0x0F),
		true,
		f.siblings[:],
		f.root,
	)
	testing.expect_value(t, err, Update_Error.Old_Root_Mismatch)
}

// CE §7's full Malformed class, per value, as the Rust oracle enforces it: a
// record naming another key, a wrong width, an unassigned enum, a non-zero
// supply key, and a malformed old value are refused before any climb.
@(test)
update_refuses_the_malformed_class :: proc(t: ^testing.T) {
	f: Update_Fixture
	update_fixture(&f)

	misbound: [BLOCKMON_RECORD_WIDTH]byte
	_, err := apply_update(
		.Blockmon,
		KEY_A,
		f.entries[0].record,
		true,
		blockmon_record(&misbound, KEY_B, 0x0F), // identifier names KEY_B
		true,
		f.siblings[:],
		f.root,
	)
	testing.expect_value(t, err, Update_Error.Malformed_Proof)

	short: [BLOCKMON_RECORD_WIDTH]byte
	_, err = apply_update(
		.Blockmon,
		KEY_A,
		f.entries[0].record,
		true,
		blockmon_record(&short, KEY_A, 0x0F)[:BLOCKMON_RECORD_WIDTH - 1],
		true,
		f.siblings[:],
		f.root,
	)
	testing.expect_value(t, err, Update_Error.Malformed_Proof)

	eb: [ENCOUNTER_RECORD_WIDTH]byte
	bad_enum := encounter_record(&eb, KEY_A, 0x0F)
	bad_enum[73] = 3 // status: unassigned
	_, err = apply_update(.Encounter, KEY_A, nil, false, bad_enum, true, f.siblings[:], f.root)
	testing.expect_value(t, err, Update_Error.Malformed_Proof)

	sb: [SUPPLY_RECORD_WIDTH]byte
	_, err = apply_update(.Supply, KEY_A, nil, false, sb[:], true, f.siblings[:], f.root)
	testing.expect_value(t, err, Update_Error.Malformed_Proof)

	// A malformed old value is refused too: the class applies to both values.
	bad_old: [BLOCKMON_RECORD_WIDTH]byte
	nb: [BLOCKMON_RECORD_WIDTH]byte
	_, err = apply_update(
		.Blockmon,
		KEY_A,
		blockmon_record(&bad_old, KEY_B, 0x0D),
		true,
		blockmon_record(&nb, KEY_A, 0x0F),
		true,
		f.siblings[:],
		f.root,
	)
	testing.expect_value(t, err, Update_Error.Malformed_Proof)
}

// The batch theorem, pinned before any store exists: permuting a normalised
// batch cannot change the root, and that root is the full derivation of the
// post-state. A path store has to reproduce exactly this.
@(test)
batch_root_survives_permutation :: proc(t: ^testing.T) {
	tree_ensure_init()

	// The batch modifies one key, deletes one and inserts two, so all three
	// transitions a key can undergo appear in a single batch.
	recs: [7][BLOCKMON_RECORD_WIDTH]byte
	base := [4]Tree_Entry {
		{key = fill_key(0x11), record = blockmon_record(&recs[0], fill_key(0x11), 0x01)},
		{key = fill_key(0x33), record = blockmon_record(&recs[1], fill_key(0x33), 0x03)},
		{key = fill_key(0x55), record = blockmon_record(&recs[2], fill_key(0x55), 0x05)},
		{key = fill_key(0x77), record = blockmon_record(&recs[3], fill_key(0x77), 0x07)},
	}
	root_before := domain_root(.Blockmon, base[:])

	// The inserts land mid-list and at the front on purpose: an insert that only
	// lands last leaves an append indistinguishable from an ordered insert.
	deltas := [4]Delta {
		{
			key = fill_key(0x11),
			record = blockmon_record(&recs[4], fill_key(0x11), 0xA1),
			present = true,
		},
		{
			key = fill_key(0x44),
			record = blockmon_record(&recs[5], fill_key(0x44), 0x04),
			present = true,
		},
		{key = fill_key(0x33), present = false},
		{
			key = fill_key(0x02),
			record = blockmon_record(&recs[6], fill_key(0x02), 0x02),
			present = true,
		},
	}

	after := [5]Tree_Entry {
		{key = fill_key(0x02), record = recs[6][:]},
		{key = fill_key(0x11), record = recs[4][:]},
		{key = fill_key(0x44), record = recs[5][:]},
		{key = fill_key(0x55), record = recs[2][:]},
		{key = fill_key(0x77), record = recs[3][:]},
	}
	want := domain_root(.Blockmon, after[:])

	order := [4]int{0, 1, 2, 3}
	seen := 0
	permute(&order, 0, proc(o: [4]int, ctx: ^Permute_Ctx) {
		permuted: [4]Delta
		for idx, i in o {
			permuted[i] = ctx.deltas[idx]
		}
		got, err := apply_batch(.Blockmon, ctx.entries[:], permuted[:], ctx.root_before)
		testing.expect_value(ctx.t, err, Batch_Error.None)
		testing.expect_value(ctx.t, got, ctx.want)
		ctx.seen^ += 1
	}, &Permute_Ctx {
		t = t,
		entries = &base,
		deltas = &deltas,
		root_before = root_before,
		want = want,
		seen = &seen,
	})
	testing.expect_value(t, seen, 24) // every permutation of four deltas
}

// Unnormalised: order would decide the result, so it is refused.
@(test)
batch_refuses_a_repeated_key :: proc(t: ^testing.T) {
	tree_ensure_init()
	rb: [3][BLOCKMON_RECORD_WIDTH]byte
	entries := [1]Tree_Entry{{key = KEY_A, record = blockmon_record(&rb[0], KEY_A, 0x0D)}}
	root := domain_root(.Blockmon, entries[:])
	deltas := [2]Delta {
		{key = KEY_A, record = blockmon_record(&rb[1], KEY_A, 0x01), present = true},
		{key = KEY_A, record = blockmon_record(&rb[2], KEY_A, 0x02), present = true},
	}
	_, err := apply_batch(.Blockmon, entries[:], deltas[:], root)
	testing.expect_value(t, err, Batch_Error.Duplicate_Key)
}

// A batch anchors like a single update.
@(test)
batch_refuses_a_wrong_claimed_root :: proc(t: ^testing.T) {
	tree_ensure_init()
	rb: [2][BLOCKMON_RECORD_WIDTH]byte
	entries := [1]Tree_Entry{{key = KEY_A, record = blockmon_record(&rb[0], KEY_A, 0x0D)}}
	wrong := domain_root(.Blockmon, entries[:])
	wrong[31] ~= 0x01
	deltas := [1]Delta{{key = KEY_B, record = blockmon_record(&rb[1], KEY_B, 0x01), present = true}}
	_, err := apply_batch(.Blockmon, entries[:], deltas[:], wrong)
	testing.expect_value(t, err, Batch_Error.Old_Root_Mismatch)
}

// With no deltas there is no climb, so nothing would anchor the claimed root:
// accepting would hand back an arbitrary root as verified.
@(test)
batch_refuses_an_empty_batch :: proc(t: ^testing.T) {
	tree_ensure_init()
	rb: [BLOCKMON_RECORD_WIDTH]byte
	entries := [1]Tree_Entry{{key = KEY_A, record = blockmon_record(&rb, KEY_A, 0x0D)}}
	bogus := fill_key(0xEE)
	_, err := apply_batch(.Blockmon, entries[:], nil, bogus)
	testing.expect_value(t, err, Batch_Error.Empty_Batch)
}

Permute_Ctx :: struct {
	t:           ^testing.T,
	entries:     ^[4]Tree_Entry,
	deltas:      ^[4]Delta,
	root_before: [32]byte,
	want:        [32]byte,
	seen:        ^int,
}

permute :: proc(
	order: ^[4]int,
	at: int,
	body: proc(o: [4]int, ctx: ^Permute_Ctx),
	ctx: ^Permute_Ctx,
) {
	if at == len(order) {
		body(order^, ctx)
		return
	}
	for i in at ..< len(order) {
		order[at], order[i] = order[i], order[at]
		permute(order, at + 1, body, ctx)
		order[at], order[i] = order[i], order[at]
	}
}

// §7 Malformed: a sibling count other than TREE_DEPTH, on both sides of it.
@(test)
update_refuses_a_malformed_proof :: proc(t: ^testing.T) {
	f: Update_Fixture
	update_fixture(&f)
	nb: [BLOCKMON_RECORD_WIDTH]byte
	new_record := blockmon_record(&nb, KEY_A, 0x0F)
	long := make([][32]byte, TREE_DEPTH + 1)
	defer delete(long)
	copy(long, f.siblings[:])

	bad := [][][32]byte{f.siblings[:TREE_DEPTH - 1], long}
	for s in bad {
		_, err := apply_update(
			.Blockmon,
			KEY_A,
			f.entries[0].record,
			true,
			new_record,
			true,
			s,
			f.root,
		)
		testing.expect_value(t, err, Update_Error.Malformed_Proof)
	}
}
