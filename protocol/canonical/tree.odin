// Authenticated state tree, canonical-encoding.md §7. One construction serves
// every state domain: the tag is always an explicit parameter, never caller
// context. Entries are sorted strictly ascending by key, which makes the
// partition at each level contiguous and the whole descent allocation-free.
package canonical

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

// Call once before any tree operation. Costs TREE_DEPTH hashes. Not @(init),
// which would have to be contextless and so could not hash at all.
tree_init :: proc() {
	empty_table[0] = protocol_hash(DOMAIN_SMT_EMPTY, nil)
	for level in 0 ..< TREE_DEPTH {
		empty_table[level + 1] = node_hash(empty_table[level], empty_table[level])
	}
	empty_table_ready = true
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

// Malformed per §7: a sibling count other than TREE_DEPTH. Key width is
// enforced by the type, and record decoding belongs to the record's own domain.
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
