package canonical

import "core:slice"
import "core:testing"

// splitmix64, as everywhere else in this repo: no OS randomness in a gate.
Store_Rng :: struct {
	s: u64,
}

store_next :: proc(r: ^Store_Rng) -> u64 {
	r.s += 0x9E37_79B9_7F4A_7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

store_key :: proc(r: ^Store_Rng) -> (out: [32]byte) {
	for i in 0 ..< 32 {
		out[i] = byte(store_next(r))
	}
	return
}

// A blockmon record bound to its key, so every entry is admissible.
store_record :: proc(buf: ^[BLOCKMON_RECORD_WIDTH]byte, key: [32]byte, r: ^Store_Rng) -> []byte {
	k := key
	copy(buf[0:32], k[:])
	for i in 32 ..< BLOCKMON_RECORD_WIDTH {
		buf[i] = byte(store_next(r))
	}
	return buf[:]
}

Store_Fixture :: struct {
	records: [][BLOCKMON_RECORD_WIDTH]byte,
	entries: []Tree_Entry,
}

store_fixture :: proc(n: int, r: ^Store_Rng) -> Store_Fixture {
	f: Store_Fixture
	f.records = make([][BLOCKMON_RECORD_WIDTH]byte, n)
	f.entries = make([]Tree_Entry, n)
	for i in 0 ..< n {
		key := store_key(r)
		f.entries[i] = Tree_Entry {
			key    = key,
			record = store_record(&f.records[i], key, r),
		}
	}
	slice.sort_by(f.entries, proc(a: Tree_Entry, b: Tree_Entry) -> bool {
		return !key_greater(a.key, b.key) && a.key != b.key
	})
	return f
}

store_fixture_destroy :: proc(f: ^Store_Fixture) {
	delete(f.records)
	delete(f.entries)
}

STORE_OCCUPANCIES := []int{0, 1, 2, 3, 8, 64, 257}

// Fewer materialised objects may not alter any hash.
@(test)
store_root_matches_full_derivation :: proc(t: ^testing.T) {
	r := Store_Rng{s = 0x0000_5107}
	for n in STORE_OCCUPANCIES {
		f := store_fixture(n, &r)
		defer store_fixture_destroy(&f)
		s: Path_Store
		store_init(&s)
		defer store_destroy(&s)
		testing.expect_value(
			t,
			store_build(&s, .Blockmon, f.entries),
			domain_root(.Blockmon, f.entries),
		)
	}
}

// Trust gate: store and walk agree at every level, for committed and
// non-committed keys.
@(test)
store_proofs_match_the_walk :: proc(t: ^testing.T) {
	r := Store_Rng{s = 0x0000_9200}
	for n in STORE_OCCUPANCIES {
		f := store_fixture(n, &r)
		defer store_fixture_destroy(&f)
		s: Path_Store
		store_init(&s)
		defer store_destroy(&s)
		store_build(&s, .Blockmon, f.entries)

		for e, i in f.entries {
			if i > 8 && i % 17 != 0 {
				continue // a sample at high occupancy keeps the gate quick
			}
			want: [TREE_DEPTH][32]byte
			tree_siblings(.Blockmon, f.entries, e.key, &want)
			got: [TREE_DEPTH][32]byte
			leaf, present := store_read_path(&s, .Blockmon, e.key, &got)
			testing.expect(t, present, "a committed key must read as present")
			testing.expect_value(t, leaf, leaf_hash(.Blockmon, e.key, e.record))
			testing.expect(t, slice.equal(got[:], want[:]), "siblings differ from the walk")
		}

		for _ in 0 ..< 4 {
			absent := store_key(&r)
			want: [TREE_DEPTH][32]byte
			tree_siblings(.Blockmon, f.entries, absent, &want)
			got: [TREE_DEPTH][32]byte
			_, present := store_read_path(&s, .Blockmon, absent, &got)
			testing.expect(t, !present, "an uncommitted key must read as absent")
			testing.expect(
				t,
				slice.equal(got[:], want[:]),
				"absence siblings differ from the walk",
			)
		}
	}
}

// Materialisation bug (post-collapse or colliding insert) visible over long
// runs of modifications, inserts and deletes.
@(test)
store_writes_track_full_derivation :: proc(t: ^testing.T) {
	r := Store_Rng{s = 0x0000_5735}
	f := store_fixture(24, &r)
	defer store_fixture_destroy(&f)

	s: Path_Store
	store_init(&s)
	defer store_destroy(&s)
	store_build(&s, .Blockmon, f.entries)

	// The model: the same mapping, derived in full each step.
	live := make([dynamic]Tree_Entry, 0, 64)
	defer delete(live)
	append(&live, ..f.entries)

	spare := make([][BLOCKMON_RECORD_WIDTH]byte, 48)
	defer delete(spare)

	for step in 0 ..< 48 {
		kind := step % 3
		key: [32]byte
		record: []byte
		present := true

		switch kind {
		case 0:
			// modify an existing key
			if len(live) == 0 {continue}
			idx := int(store_next(&r) % u64(len(live)))
			key = live[idx].key
			record = store_record(&spare[step], key, &r)
			live[idx].record = record
		case 1:
			// insert a fresh key
			key = store_key(&r)
			record = store_record(&spare[step], key, &r)
			entry_write(&live, Delta{key = key, record = record, present = true})
		case 2:
			// delete an existing key
			if len(live) == 0 {continue}
			idx := int(store_next(&r) % u64(len(live)))
			key = live[idx].key
			present = false
			entry_write(&live, Delta{key = key, present = false})
		}

		leaf: [32]byte
		if present {
			leaf = leaf_hash(.Blockmon, key, record)
		}
		got := store_write(&s, .Blockmon, key, leaf, present)
		testing.expect_value(t, got, domain_root(.Blockmon, live[:]))

		want: [TREE_DEPTH][32]byte
		tree_siblings(.Blockmon, live[:], key, &want)
		after: [TREE_DEPTH][32]byte
		_, still := store_read_path(&s, .Blockmon, key, &after)
		testing.expect_value(t, still, present)
		testing.expect(t, slice.equal(after[:], want[:]), "post-write siblings differ")

		// Materialisation depends on the key set, so churn must match a fresh build.
		// Otherwise, a write path that never collapses stays correct but bloats.
		fresh: Path_Store
		store_init(&fresh)
		store_build(&fresh, .Blockmon, live[:])
		testing.expect_value(t, len(s.nodes), len(fresh.nodes))
		testing.expect_value(t, len(s.singletons), len(fresh.singletons))
		for c, n in fresh.nodes {
			other, found := s.nodes[c]
			testing.expect(t, found, "the written store is missing a node a rebuild holds")
			testing.expect_value(t, other, n)
		}
		for c, single in fresh.singletons {
			other, found := s.singletons[c]
			testing.expect(t, found, "the written store is missing a locator")
			testing.expect_value(t, other, single)
		}
		store_destroy(&fresh)
	}
}

// The policy-derived levels, computed without the store.
count_stored_levels :: proc(sorted: []Tree_Entry, depth: int) -> int {
	if len(sorted) < 2 {
		return 0
	}
	split := tree_partition(sorted, depth)
	return 1 +
		count_stored_levels(sorted[:split], depth + 1) +
		count_stored_levels(sorted[split:], depth + 1)
}

// More than one node per branch point: the single-child levels above a branch
// point hold both its keys, so they are stored too. Still O(n) with a small
// constant, against 256 per key for a full path materialisation.
@(test)
store_holds_one_locator_per_key_and_a_node_per_shared_level :: proc(t: ^testing.T) {
	r := Store_Rng{s = 0x0000_51D3}
	for n in ([]int{1, 2, 8, 64}) {
		f := store_fixture(n, &r)
		defer store_fixture_destroy(&f)
		s: Path_Store
		store_init(&s)
		defer store_destroy(&s)
		store_build(&s, .Blockmon, f.entries)
		testing.expect_value(t, len(s.singletons), n)
		testing.expect_value(t, len(s.nodes), count_stored_levels(f.entries, 0))
		testing.expect(
			t,
			len(s.nodes) + len(s.singletons) < 4 * n + 4,
			"materialisation must stay O(n), not O(256n)",
		)
	}
}

// Reads scale with tree depth, not population size.
@(test)
store_reads_are_bounded_by_depth :: proc(t: ^testing.T) {
	r := Store_Rng{s = 0x0000_B0DD}
	for n in ([]int{8, 64, 257}) {
		f := store_fixture(n, &r)
		defer store_fixture_destroy(&f)
		s: Path_Store
		store_init(&s)
		defer store_destroy(&s)
		store_build(&s, .Blockmon, f.entries)

		s.node_reads = 0
		out: [TREE_DEPTH][32]byte
		store_read_path(&s, .Blockmon, f.entries[n / 2].key, &out)
		testing.expect(
			t,
			s.node_reads <= u64(TREE_DEPTH),
			"a read path must not exceed the tree's depth",
		)
	}
}

// Derived, not a second source of truth: the objects are identical, not
// just the root.
@(test)
store_rebuild_is_deterministic :: proc(t: ^testing.T) {
	r := Store_Rng{s = 0x0000_3BD1}
	f := store_fixture(32, &r)
	defer store_fixture_destroy(&f)

	a: Path_Store
	store_init(&a)
	defer store_destroy(&a)
	root_a := store_build(&a, .Blockmon, f.entries)

	b: Path_Store
	store_init(&b)
	defer store_destroy(&b)
	root_b := store_build(&b, .Blockmon, f.entries)

	testing.expect_value(t, root_a, root_b)
	testing.expect_value(t, len(a.nodes), len(b.nodes))
	testing.expect_value(t, len(a.singletons), len(b.singletons))
	for c, n in a.nodes {
		other, found := b.nodes[c]
		testing.expect(t, found, "a node is missing from the rebuild")
		testing.expect_value(t, other, n)
	}
	for c, single in a.singletons {
		other, found := b.singletons[c]
		testing.expect(t, found, "a locator is missing from the rebuild")
		testing.expect_value(t, other, single)
	}
}
