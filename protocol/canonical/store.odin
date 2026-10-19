// Materialised storage for the §7 tree (register Q19).
// The commitment is always the one from subtree_root; only the persisted
// structure varies.
//
// Persist a node only if it cannot be derived from the key set and the empty
// ladder. This leaves two cases: a branch with two children holding multiple
// keys, and a locator at the top of a maximal single-key chain. Empty subtrees
// are ladder constants; single-key subtrees are climbable.
//
// Locators store the leaf alongside the key. When an insert collides with a
// singleton, the chain below the new divergence point is rebuilt. Deriving the
// leaf from the record would place canonical state back in the authenticated
// path.
package canonical

Path_Node :: struct {
	left:  [32]byte,
	right: [32]byte,
}

Singleton :: struct {
	key:  [32]byte,
	leaf: [32]byte,
}

// §7's hash figures omit the read and write axes.
Path_Store :: struct {
	nodes:          map[[32]byte]Path_Node,
	singletons:     map[[32]byte]Singleton,
	subject_root:   [32]byte,
	blockmon_root:  [32]byte,
	encounter_root: [32]byte,
	supply_root:    [32]byte,
	node_reads:     u64,
	node_writes:    u64,
	hashes:         u64,
}

store_init :: proc(s: ^Path_Store) {
	tree_ensure_init()
	s.nodes = make(map[[32]byte]Path_Node)
	s.singletons = make(map[[32]byte]Singleton)
	s.subject_root = empty_root()
	s.blockmon_root = empty_root()
	s.encounter_root = empty_root()
	s.supply_root = empty_root()
}

store_destroy :: proc(s: ^Path_Store) {
	delete(s.nodes)
	delete(s.singletons)
}

// By field name, as §7 requires of anything that maps domains to roots.
store_root :: proc(s: ^Path_Store, tag: Domain_Tag) -> [32]byte {
	switch tag {
	case .Subject:
		return s.subject_root
	case .Blockmon:
		return s.blockmon_root
	case .Encounter:
		return s.encounter_root
	case .Supply:
		return s.supply_root
	}
	return {}
}

set_store_root :: proc(s: ^Path_Store, tag: Domain_Tag, root: [32]byte) {
	switch tag {
	case .Subject:
		s.subject_root = root
	case .Blockmon:
		s.blockmon_root = root
	case .Encounter:
		s.encounter_root = root
	case .Supply:
		s.supply_root = root
	}
}

Subtree_Class :: enum {
	Empty,
	Singleton,
	Branch,
}

// The filing location of a commitment determines its class; the three
// classes are exhaustive.
store_classify :: proc(
	s: ^Path_Store,
	commitment: [32]byte,
	depth: int,
) -> (
	class: Subtree_Class,
	single: Singleton,
) {
	if commitment == empty_commitment(TREE_DEPTH - depth) {
		return .Empty, {}
	}
	if entry, found := s.singletons[commitment]; found {
		s.node_reads += 1
		return .Singleton, entry
	}
	s.node_reads += 1
	return .Branch, {}
}

chain_commitment :: proc(s: ^Path_Store, key: [32]byte, leaf: [32]byte, depth: int) -> [32]byte {
	c := leaf
	for level := TREE_DEPTH - 1; level >= depth; level -= 1 {
		empty := empty_commitment(TREE_DEPTH - 1 - level)
		c = tree_bit(key, level) == 1 ? node_hash(empty, c) : node_hash(c, empty)
		s.hashes += 1
	}
	return c
}

// entries must be sorted, as the descent's partition depends on it.
store_build :: proc(s: ^Path_Store, tag: Domain_Tag, sorted: []Tree_Entry) -> [32]byte {
	root := store_materialise(s, tag, sorted, 0)
	set_store_root(s, tag, root)
	return root
}

store_materialise :: proc(
	s: ^Path_Store,
	tag: Domain_Tag,
	sorted: []Tree_Entry,
	depth: int,
) -> [32]byte {
	if len(sorted) == 0 {
		return empty_commitment(TREE_DEPTH - depth)
	}
	if len(sorted) == 1 {
		leaf := leaf_hash(tag, sorted[0].key, sorted[0].record)
		s.hashes += 1
		c := chain_commitment(s, sorted[0].key, leaf, depth)
		s.singletons[c] = Singleton {
			key  = sorted[0].key,
			leaf = leaf,
		}
		s.node_writes += 1
		return c
	}
	split := tree_partition(sorted, depth)
	left := store_materialise(s, tag, sorted[:split], depth + 1)
	right := store_materialise(s, tag, sorted[split:], depth + 1)
	c := node_hash(left, right)
	s.hashes += 1
	s.nodes[c] = Path_Node {
		left  = left,
		right = right,
	}
	s.node_writes += 1
	return c
}

// Access §2's per-operation clause: max TREE_DEPTH levels, regardless of
// population.
store_read_path :: proc(
	s: ^Path_Store,
	tag: Domain_Tag,
	key: [32]byte,
	out: ^[TREE_DEPTH][32]byte,
) -> (
	leaf: [32]byte,
	present: bool,
) {
	c := store_root(s, tag)
	depth := 0

	for depth < TREE_DEPTH {
		class, single := store_classify(s, c, depth)
		switch class {
		case .Empty:
			for d in depth ..< TREE_DEPTH {
				out[TREE_DEPTH - 1 - d] = empty_commitment(TREE_DEPTH - 1 - d)
			}
			return {}, false
		case .Singleton:
			// The chain is derivable, so the rest costs no reads.
			return store_read_under_singleton(s, key, single, depth, out)
		case .Branch:
			node := s.nodes[c]
			if tree_bit(key, depth) == 1 {
				out[TREE_DEPTH - 1 - depth] = node.left
				c = node.right
			} else {
				out[TREE_DEPTH - 1 - depth] = node.right
				c = node.left
			}
			depth += 1
		}
	}
	return {}, false // unreachable: a branch node cannot sit at the leaf level
}

// Single-key subtree: empty siblings until bits diverge, other key's chain
// at that level, empty below.
store_read_under_singleton :: proc(
	s: ^Path_Store,
	key: [32]byte,
	single: Singleton,
	depth: int,
	out: ^[TREE_DEPTH][32]byte,
) -> (
	leaf: [32]byte,
	present: bool,
) {
	if single.key == key {
		for d in depth ..< TREE_DEPTH {
			out[TREE_DEPTH - 1 - d] = empty_commitment(TREE_DEPTH - 1 - d)
		}
		return single.leaf, true
	}
	for d in depth ..< TREE_DEPTH {
		if tree_bit(key, d) == tree_bit(single.key, d) {
			out[TREE_DEPTH - 1 - d] = empty_commitment(TREE_DEPTH - 1 - d)
			continue
		}
		out[TREE_DEPTH - 1 - d] = chain_commitment(s, single.key, single.leaf, d + 1)
		for rest in d + 1 ..< TREE_DEPTH {
			out[TREE_DEPTH - 1 - rest] = empty_commitment(TREE_DEPTH - 1 - rest)
		}
		return {}, false
	}
	return {}, false // two distinct keys cannot agree on all 256 bits
}

// Rebuilt bottom-up: each level's materialisation follows from its children's
// classes, so a delete leaving one key under a node collapses it back to a
// chain instead of stranding it.
store_write :: proc(
	s: ^Path_Store,
	tag: Domain_Tag,
	key: [32]byte,
	leaf: [32]byte,
	present: bool,
) -> [32]byte {
	Frame :: struct {
		commitment: [32]byte,
		sibling:    [32]byte,
		depth:      int,
		bit:        u8,
	}
	path: [TREE_DEPTH]Frame
	levels := 0

	c := store_root(s, tag)
	depth := 0
	terminal_class: Subtree_Class
	terminal_single: Singleton

	for depth < TREE_DEPTH {
		class, single := store_classify(s, c, depth)
		if class != .Branch {
			terminal_class = class
			terminal_single = single
			break
		}
		node := s.nodes[c]
		bit := tree_bit(key, depth)
		path[levels] = Frame {
			commitment = c,
			sibling    = bit == 1 ? node.left : node.right,
			depth      = depth,
			bit        = bit,
		}
		levels += 1
		c = bit == 1 ? node.right : node.left
		depth += 1
	}

	sub := store_subtree_after_write(
		s,
		key,
		leaf,
		present,
		depth,
		terminal_class,
		terminal_single,
		c,
	)

	// Dropping any level that no longer holds two keys.
	for i := levels - 1; i >= 0; i -= 1 {
		f := path[i]
		delete_key(&s.nodes, f.commitment)
		left := f.bit == 1 ? f.sibling : sub
		right := f.bit == 1 ? sub : f.sibling
		sub = store_join(s, left, right, f.depth)
	}
	set_store_root(s, tag, sub)
	return sub
}

// What this level commits, and whether it is worth storing.
store_join :: proc(s: ^Path_Store, left: [32]byte, right: [32]byte, depth: int) -> [32]byte {
	left_class, left_single := store_classify(s, left, depth + 1)
	right_class, right_single := store_classify(s, right, depth + 1)

	if left_class == .Empty && right_class == .Empty {
		return empty_commitment(TREE_DEPTH - depth)
	}
	// One key below: chain, not branch, so the locator moves up.
	if left_class == .Empty && right_class == .Singleton {
		delete_key(&s.singletons, right)
		return store_file_singleton(s, right_single, depth)
	}
	if right_class == .Empty && left_class == .Singleton {
		delete_key(&s.singletons, left)
		return store_file_singleton(s, left_single, depth)
	}

	c := node_hash(left, right)
	s.hashes += 1
	s.nodes[c] = Path_Node {
		left  = left,
		right = right,
	}
	s.node_writes += 1
	return c
}

store_file_singleton :: proc(s: ^Path_Store, single: Singleton, depth: int) -> [32]byte {
	c := chain_commitment(s, single.key, single.leaf, depth)
	s.singletons[c] = single
	s.node_writes += 1
	return c
}

store_subtree_after_write :: proc(
	s: ^Path_Store,
	key: [32]byte,
	leaf: [32]byte,
	present: bool,
	depth: int,
	class: Subtree_Class,
	single: Singleton,
	commitment: [32]byte,
) -> [32]byte {
	if !present {
		switch class {
		case .Empty, .Branch:
			return empty_commitment(TREE_DEPTH - depth) // absent already, or unreachable
		case .Singleton:
			if single.key != key {
				return commitment // a different key lives here; nothing to remove
			}
			delete_key(&s.singletons, commitment)
			return empty_commitment(TREE_DEPTH - depth)
		}
	}

	switch class {
	case .Empty:
		return store_file_singleton(s, Singleton{key = key, leaf = leaf}, depth)
	case .Singleton:
		if single.key == key {
			delete_key(&s.singletons, commitment)
			return store_file_singleton(s, Singleton{key = key, leaf = leaf}, depth)
		}
		// The case that needs the resident key's leaf, not just its key.
		delete_key(&s.singletons, commitment)
		return store_split_pair(s, Singleton{key = key, leaf = leaf}, single, depth)
	case .Branch:
		return commitment // unreachable: the walk stops at empty or singleton
	}
	return commitment
}

// Chain to the first differing bit, then a branch over the two chains.
store_split_pair :: proc(
	s: ^Path_Store,
	a: Singleton,
	b: Singleton,
	depth: int,
) -> [32]byte {
	for d in depth ..< TREE_DEPTH {
		if tree_bit(a.key, d) == tree_bit(b.key, d) {
			continue
		}
		a_side := store_file_singleton(s, a, d + 1)
		b_side := store_file_singleton(s, b, d + 1)
		left := tree_bit(a.key, d) == 0 ? a_side : b_side
		right := tree_bit(a.key, d) == 0 ? b_side : a_side
		c := node_hash(left, right)
		s.hashes += 1
		s.nodes[c] = Path_Node {
			left  = left,
			right = right,
		}
		s.node_writes += 1
		// Every level down to d holds both keys, so each is a branch.
		for level := d - 1; level >= depth; level -= 1 {
			empty := empty_commitment(TREE_DEPTH - 1 - level)
			l := tree_bit(a.key, level) == 1 ? empty : c
			r := tree_bit(a.key, level) == 1 ? c : empty
			c = node_hash(l, r)
			s.hashes += 1
			s.nodes[c] = Path_Node {
				left  = l,
				right = r,
			}
			s.node_writes += 1
		}
		return c
	}
	return empty_commitment(TREE_DEPTH - depth) // unreachable for distinct keys
}
