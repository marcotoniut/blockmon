// Authenticated state tree, canonical-encoding.md §7. One construction serves
// every state domain: the tag is always an explicit parameter, never caller
// context. Entries are sorted strictly ascending by key, which makes the
// partition at each level contiguous and the whole descent allocation-free.
package canonical

import "core:sync"

DOMAIN_SMT_LEAF :: "blockmon/smt-leaf/v0"
DOMAIN_SMT_NODE :: "blockmon/smt-node/v0"
DOMAIN_SMT_EMPTY :: "blockmon/smt-empty/v0"
DOMAIN_WORLD_V1 :: "blockmon/world/v1"

TREE_DEPTH :: 256

Domain_Tag :: enum u8 {
	Subject   = 1,
	Blockmon  = 2,
	Encounter = 3,
	Supply    = 4,
}

Tree_Entry :: struct {
	key:    [32]byte,
	record: []byte,
}

// empty_table[0] is a vacant leaf slot; empty_table[TREE_DEPTH] an empty domain.
empty_table: [TREE_DEPTH + 1][32]byte
empty_table_ready: bool
tree_once: sync.Once

// Call once before any tree operation. Costs TREE_DEPTH hashes. Not @(init),
// which would have to be contextless and so could not hash at all.
tree_init :: proc() {
	empty_table[0] = protocol_hash(DOMAIN_SMT_EMPTY, nil)
	for level in 0 ..< TREE_DEPTH {
		empty_table[level + 1] = node_hash(empty_table[level], empty_table[level])
	}
	empty_table_ready = true
}

// Race-free: a simple check-then-write lets one test thread see the ready
// flag before the table's writes.
tree_ensure_init :: proc() {
	sync.once_do(&tree_once, tree_init)
}

empty_commitment :: proc(level: int) -> [32]byte {
	assert(empty_table_ready, "canonical.tree_init must run before any tree operation")
	return empty_table[level]
}

empty_root :: proc() -> [32]byte {
	return empty_commitment(TREE_DEPTH)
}

// bit(i) is the (i mod 8)-th most significant bit of byte i / 8.
tree_bit :: proc(key: [32]byte, i: int) -> u8 {
	return (key[i / 8] >> (7 - u8(i % 8))) & 1
}

leaf_hash :: proc(tag: Domain_Tag, key: [32]byte, record: []byte) -> [32]byte {
	k := key
	buf: [dynamic]byte
	defer delete(buf)
	append(&buf, u8(tag))
	append(&buf, ..k[:])
	append(&buf, ..record)
	return protocol_hash(DOMAIN_SMT_LEAF, buf[:])
}

node_hash :: proc(left: [32]byte, right: [32]byte) -> [32]byte {
	l, r := left, right
	buf: [64]byte
	copy(buf[0:32], l[:])
	copy(buf[32:64], r[:])
	return protocol_hash(DOMAIN_SMT_NODE, buf[:])
}

// First index whose bit at this level is 1. Sorted keys make it a boundary.
tree_partition :: proc(sorted: []Tree_Entry, depth: int) -> int {
	for e, i in sorted {
		if tree_bit(e.key, depth) == 1 {
			return i
		}
	}
	return len(sorted)
}

// Commitment of the subtree at level TREE_DEPTH - depth. A node with one empty
// child is hashed like any other: there is no path collapse.
subtree_root :: proc(tag: Domain_Tag, sorted: []Tree_Entry, depth: int) -> [32]byte {
	if len(sorted) == 0 {
		return empty_commitment(TREE_DEPTH - depth)
	}
	if depth == TREE_DEPTH {
		// A duplicate key: hashing only sorted[0] would give two states one root.
		assert(len(sorted) == 1, "duplicate key: domain state is a mapping")
		return leaf_hash(tag, sorted[0].key, sorted[0].record)
	}
	split := tree_partition(sorted, depth)
	return node_hash(
		subtree_root(tag, sorted[:split], depth + 1),
		subtree_root(tag, sorted[split:], depth + 1),
	)
}

domain_root :: proc(tag: Domain_Tag, sorted: []Tree_Entry) -> [32]byte {
	return subtree_root(tag, sorted, 0)
}

// The TREE_DEPTH sibling commitments for key, written leaf to root.
tree_siblings :: proc(
	tag: Domain_Tag,
	sorted: []Tree_Entry,
	key: [32]byte,
	out: ^[TREE_DEPTH][32]byte,
) {
	live := sorted
	for depth in 0 ..< TREE_DEPTH {
		split := tree_partition(live, depth)
		if tree_bit(key, depth) == 0 {
			out[TREE_DEPTH - 1 - depth] = subtree_root(tag, live[split:], depth + 1)
			live = live[:split]
		} else {
			out[TREE_DEPTH - 1 - depth] = subtree_root(tag, live[:split], depth + 1)
			live = live[split:]
		}
	}
}

// What a verifier does: recompute the domain root from a leaf and its siblings.
tree_climb :: proc(key: [32]byte, leaf: [32]byte, siblings: [][32]byte) -> [32]byte {
	v := leaf
	for d in 0 ..< len(siblings) {
		s := siblings[d]
		if tree_bit(key, TREE_DEPTH - 1 - d) == 1 {
			v = node_hash(s, v)
		} else {
			v = node_hash(v, s)
		}
	}
	return v
}

root_from_proof :: proc(
	tag: Domain_Tag,
	key: [32]byte,
	record: []byte,
	siblings: [][32]byte,
) -> [32]byte {
	return tree_climb(key, leaf_hash(tag, key, record), siblings)
}

root_from_absence :: proc(key: [32]byte, siblings: [][32]byte) -> [32]byte {
	return tree_climb(key, empty_commitment(0), siblings)
}

Update_Error :: enum {
	None,
	Malformed_Proof,
	Old_Root_Mismatch,
}

// Fixed-width fields mean §2's exact-consume decoding is just a width check
// plus assigned enum values.
BLOCKMON_RECORD_WIDTH :: 96
ENCOUNTER_RECORD_WIDTH :: 74
SUPPLY_RECORD_WIDTH :: 40

// §7 Malformed for one value: shape, enum values, and the identifier binding.
record_admissible :: proc(tag: Domain_Tag, key: [32]byte, record: []byte) -> bool {
	k := key
	switch tag {
	case .Subject:
		return len(record) == 0
	case .Blockmon:
		return len(record) == BLOCKMON_RECORD_WIDTH && bytes_eq(record[0:32], k[:])
	case .Encounter:
		if len(record) != ENCOUNTER_RECORD_WIDTH {
			return false
		}
		if record[64] != 1 { // encounter_class: COMMON = 1
			return false
		}
		if record[73] != 1 && record[73] != 2 { // status: RESERVED = 1, CONSUMED = 2
			return false
		}
		return bytes_eq(record[0:32], k[:])
	case .Supply:
		return len(record) == SUPPLY_RECORD_WIDTH
	}
	return false // an unassigned tag admits nothing
}

bytes_eq :: proc(a: []byte, b: []byte) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if v != b[i] {
			return false
		}
	}
	return true
}

// Fixed to the pre-state, so it can't be a fast root constructor.
// The single sibling sequence drives both climbs; only the leaf moves. Both
// values retain the full Malformed class from §7, as the Rust oracle does.
apply_update :: proc(
	tag: Domain_Tag,
	key: [32]byte,
	old_record: []byte,
	old_present: bool,
	new_record: []byte,
	new_present: bool,
	siblings: [][32]byte,
	claimed_old_root: [32]byte,
) -> (
	new_root: [32]byte,
	err: Update_Error,
) {
	tree_ensure_init()
	if !proof_wellformed(siblings) {
		return {}, .Malformed_Proof
	}
	if tag == .Supply && key != supply_singleton_key() {
		return {}, .Malformed_Proof
	}
	if old_present && !record_admissible(tag, key, old_record) {
		return {}, .Malformed_Proof
	}
	if new_present && !record_admissible(tag, key, new_record) {
		return {}, .Malformed_Proof
	}
	old_leaf := empty_commitment(0)
	if old_present {
		old_leaf = leaf_hash(tag, key, old_record)
	}
	if tree_climb(key, old_leaf, siblings) != claimed_old_root {
		return {}, .Old_Root_Mismatch
	}
	new_leaf := empty_commitment(0)
	if new_present {
		new_leaf = leaf_hash(tag, key, new_record)
	}
	return tree_climb(key, new_leaf, siblings), .None
}

// A key's final value. Since each key has at most one delta, the old value
// is independent of the delta's position within the batch.
Delta :: struct {
	key:     [32]byte,
	record:  []byte,
	present: bool, // false: the key is absent once the batch applies
}

Batch_Error :: enum {
	None,
	Malformed_Proof,
	Old_Root_Mismatch,
	Duplicate_Key, // unnormalised: order would decide the result
	// Climbs are the sole anchor, so an empty batch leaves its claimed root unverified.
	Empty_Batch,
}

// CE §7: for a normalised batch the resulting root is independent of delta
// order, because the leaf set is fixed and every node commits the leaves
// below it. Siblings come from the entries as the batch has left them; a
// second key in a domain sees the first key's write. entries must be sorted.
apply_batch :: proc(
	tag: Domain_Tag,
	entries: []Tree_Entry,
	deltas: []Delta,
	claimed_old_root: [32]byte,
	allocator := context.allocator,
) -> (
	new_root: [32]byte,
	err: Batch_Error,
) {
	tree_ensure_init()
	if len(deltas) == 0 {
		return {}, .Empty_Batch
	}
	for a, i in deltas {
		for b in deltas[i + 1:] {
			if a.key == b.key {
				return {}, .Duplicate_Key
			}
		}
	}

	live := make([dynamic]Tree_Entry, 0, len(entries) + len(deltas), allocator)
	defer delete(live)
	append(&live, ..entries)

	root := claimed_old_root
	for d in deltas {
		old_record, old_present := entry_at(live[:], d.key)

		sibs: [TREE_DEPTH][32]byte
		tree_siblings(tag, live[:], d.key, &sibs)

		next, uerr := apply_update(
			tag,
			d.key,
			old_record,
			old_present,
			d.record,
			d.present,
			sibs[:],
			root,
		)
		switch uerr {
		case .None:
		case .Malformed_Proof:
			return {}, .Malformed_Proof
		case .Old_Root_Mismatch:
			return {}, .Old_Root_Mismatch
		}
		root = next
		entry_write(&live, d)
	}
	return root, .None
}

entry_at :: proc(entries: []Tree_Entry, key: [32]byte) -> (record: []byte, present: bool) {
	for e in entries {
		if e.key == key {
			return e.record, true
		}
	}
	return nil, false
}

// Stores the ascending order the descent partition relies on.
entry_write :: proc(live: ^[dynamic]Tree_Entry, d: Delta) {
	at := len(live)
	for e, i in live {
		if e.key == d.key {
			if d.present {
				live[i] = Tree_Entry{key = d.key, record = d.record}
			} else {
				ordered_remove(live, i)
			}
			return
		}
		if key_greater(e.key, d.key) {
			at = i
			break
		}
	}
	if d.present {
		inject_at(live, at, Tree_Entry{key = d.key, record = d.record})
	}
}

key_greater :: proc(a: [32]byte, b: [32]byte) -> bool {
	for i in 0 ..< 32 {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}

// The shape arm of §7's Malformed class; record admissibility is checked per
// value in apply_update, at the proof boundary as the spec requires.
proof_wellformed :: proc(siblings: [][32]byte) -> bool {
	return len(siblings) == TREE_DEPTH
}

// The supply domain's only admissible key.
supply_singleton_key :: proc() -> [32]byte {
	return [32]byte{}
}

encode_world_commitment_v1 :: proc(
	subject_root: [32]byte,
	blockmon_root: [32]byte,
	encounter_root: [32]byte,
	supply_root: [32]byte,
) -> [128]byte {
	s_root, b_root, e_root, p_root := subject_root, blockmon_root, encounter_root, supply_root
	buf: [128]byte
	copy(buf[0:32], s_root[:])
	copy(buf[32:64], b_root[:])
	copy(buf[64:96], e_root[:])
	copy(buf[96:128], p_root[:])
	return buf
}

world_commitment_v1 :: proc(
	subject_root: [32]byte,
	blockmon_root: [32]byte,
	encounter_root: [32]byte,
	supply_root: [32]byte,
) -> [32]byte {
	buf := encode_world_commitment_v1(subject_root, blockmon_root, encounter_root, supply_root)
	return protocol_hash(DOMAIN_WORLD_V1, buf[:])
}
