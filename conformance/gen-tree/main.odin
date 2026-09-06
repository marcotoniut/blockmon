// v1 authenticated-tree expansion corpus. Generator-produced and deliberately
// separate evidence from the hand-derived constitutional tier, which it never
// replaces: that tier pins the meaning, this one supplies volume. Deterministic
// from a pinned literal seed. Every case records its source inputs, not only
// its hashes, so an independent implementation re-derives rather than compares.
//
// This program never touches the v0 generator or the v0 corpora.
package gen_tree

import canonical "../../protocol/canonical"

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

TREE_V1_SEED: u64 : 0x7EE1_C0DE_5EED

out: strings.Builder

emit :: proc(format: string, args: ..any) {
	fmt.sbprintf(&out, format, ..args)
}

hx :: proc(b: []byte) -> string {
	s, _ := hex.encode(b)
	return fmt.tprintf("0x%s", string(s))
}

hx32 :: proc(v: [32]byte) -> string {
	b := v
	return hx(b[:])
}

// splitmix64, as in conformance/fuzz and the v0 expansion tier.
Rng :: struct {
	s: u64,
}

next_u64 :: proc(r: ^Rng) -> u64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

rand_key :: proc(r: ^Rng) -> [32]byte {
	k: [32]byte
	for i in 0 ..< 32 {
		k[i] = byte(next_u64(r))
	}
	return k
}

be64 :: proc(buf: ^[dynamic]byte, v: u64) {
	for i in 0 ..< 8 {
		append(buf, byte(v >> uint(56 - 8 * i)))
	}
}

key_less :: proc(a: canonical.Tree_Entry, b: canonical.Tree_Entry) -> bool {
	for i in 0 ..< 32 {
		if a.key[i] != b.key[i] {
			return a.key[i] < b.key[i]
		}
	}
	return false
}

// Well-formed records for each domain, per canonical-encoding.md §6.
mk_record :: proc(tag: canonical.Domain_Tag, key: [32]byte, r: ^Rng) -> []byte {
	k := key
	buf: [dynamic]byte
	switch tag {
	case .Subject:
		return nil
	case .Blockmon:
		append(&buf, ..k[:])
		owner := rand_key(r)
		origin := rand_key(r)
		append(&buf, ..owner[:])
		append(&buf, ..origin[:])
	case .Encounter:
		append(&buf, ..k[:])
		subject := rand_key(r)
		append(&buf, ..subject[:])
		append(&buf, 1) // encounter_class COMMON
		be64(&buf, next_u64(r) % 100_000)
		append(&buf, byte(1 + next_u64(r) % 2)) // status RESERVED or CONSUMED
	case .Supply:
		envelope := 1000 + next_u64(r) % 1000
		minted := next_u64(r) % envelope
		consumed := next_u64(r) % (minted + 1)
		created := next_u64(r) % (consumed + 1)
		be64(&buf, next_u64(r) % 8)
		be64(&buf, envelope)
		be64(&buf, minted)
		be64(&buf, consumed)
		be64(&buf, created)
	}
	return buf[:]
}

mk_entries :: proc(tag: canonical.Domain_Tag, n: int, r: ^Rng) -> []canonical.Tree_Entry {
	if n == 0 {
		return nil
	}
	es := make([]canonical.Tree_Entry, n)
	for i in 0 ..< n {
		k := tag == .Supply ? canonical.supply_singleton_key() : rand_key(r)
		es[i] = canonical.Tree_Entry {
			key    = k,
			record = mk_record(tag, k, r),
		}
	}
	slice.sort_by(es, key_less)
	return es
}

domain_name :: proc(tag: canonical.Domain_Tag) -> string {
	switch tag {
	case .Subject:
		return "subject"
	case .Blockmon:
		return "blockmon"
	case .Encounter:
		return "encounter"
	case .Supply:
		return "supply"
	}
	return "?"
}

// A key is either committed or not, before and after: there is no fourth kind.
Update_Kind :: enum {
	Modify,
	Insert,
	Delete,
}

kind_name :: proc(k: Update_Kind) -> string {
	switch k {
	case .Modify:
		return "modify"
	case .Insert:
		return "insert"
	case .Delete:
		return "delete"
	}
	return "?"
}

emit_entries :: proc(entries: []canonical.Tree_Entry) {
	emit("[")
	for e, i in entries {
		if i > 0 {
			emit(", ")
		}
		emit("{{\"key\": \"%s\", \"record_bytes\": \"%s\"}}", hx32(e.key), hx(e.record))
	}
	emit("]")
}

emit_siblings :: proc(sibs: [][32]byte) {
	emit("[")
	for sib, i in sibs {
		if i > 0 {
			emit(", ")
		}
		emit("\"%s\"", hx32(sib))
	}
	emit("]")
}

// A proof with its whole sibling sequence, so a re-deriving implementation can
// disagree at a level rather than only at a root.
emit_proof :: proc(tag: canonical.Domain_Tag, entries: []canonical.Tree_Entry, key: [32]byte) {
	present := false
	leaf := canonical.empty_commitment(0)
	for e in entries {
		if e.key == key {
			present = true
			leaf = canonical.leaf_hash(tag, e.key, e.record)
			break
		}
	}
	sibs: [canonical.TREE_DEPTH][32]byte
	canonical.tree_siblings(tag, entries, key, &sibs)
	emit(
		"{{\"tag\": %d, \"domain\": \"%s\", \"key\": \"%s\", \"present\": %t, \"leaf\": \"%s\"",
		u8(tag),
		domain_name(tag),
		hx32(key),
		present,
		hx32(leaf),
	)
	if present {
		for e in entries {
			if e.key == key {
				emit(", \"record_bytes\": \"%s\"", hx(e.record))
				break
			}
		}
	}
	emit(", \"domain_root\": \"%s\", \"siblings_leaf_to_root\": ", hx32(canonical.domain_root(tag, entries)))
	emit_siblings(sibs[:])
	emit("}}")
}

// root_after is the full post-state derivation, not the bounded path's own
// output, so agreement between the two proves the paths coincide.
emit_update :: proc(tag: canonical.Domain_Tag, kind: Update_Kind, n: int, r: ^Rng) {
	before := mk_entries(tag, n, r)

	present_before := kind != .Insert
	present_after := kind != .Delete
	key: [32]byte
	switch kind {
	case .Modify, .Delete:
		key = before[n / 2].key
	case .Insert:
		key = tag == .Supply ? canonical.supply_singleton_key() : rand_key(r)
	}

	record_before: []byte
	if present_before {
		for e in before {
			if e.key == key {
				record_before = e.record
				break
			}
		}
	}
	record_after: []byte
	if present_after {
		record_after = mk_record(tag, key, r)
	}

	after := make([dynamic]canonical.Tree_Entry)
	defer delete(after)
	for e in before {
		if e.key != key {
			append(&after, e)
		}
	}
	if present_after {
		append(&after, canonical.Tree_Entry{key = key, record = record_after})
	}
	slice.sort_by(after[:], key_less)

	root_before := canonical.domain_root(tag, before)
	root_after := canonical.domain_root(tag, after[:])

	sibs: [canonical.TREE_DEPTH][32]byte
	canonical.tree_siblings(tag, before, key, &sibs)
	sibs_after: [canonical.TREE_DEPTH][32]byte
	canonical.tree_siblings(tag, after[:], key, &sibs_after)

	// Siblings commit subtrees that exclude the key, leaving only the leaf to move.
	// This property underpins pre-state proof reuse for both inserts and deletes.
	if !slice.equal(sibs[:], sibs_after[:]) {
		fmt.eprintfln("sibling set moved: %s %s n=%d", domain_name(tag), kind_name(kind), n)
		os.exit(1)
	}
	bounded, err := canonical.apply_update(
		tag,
		key,
		record_before,
		present_before,
		record_after,
		present_after,
		sibs[:],
		root_before,
	)
	if err != .None || bounded != root_after {
		fmt.eprintfln(
			"bounded update disagrees with full derivation: %s %s n=%d",
			domain_name(tag),
			kind_name(kind),
			n,
		)
		os.exit(1)
	}

	emit(
		"    {{\"tag\": %d, \"domain\": \"%s\", \"count\": %d, \"kind\": \"%s\", \"key\": \"%s\", \"entries_before\": ",
		u8(tag),
		domain_name(tag),
		n,
		kind_name(kind),
		hx32(key),
	)
	emit_entries(before)
	emit(", \"present_before\": %t, \"record_before\": ", present_before)
	if present_before {
		emit("\"%s\"", hx(record_before))
	} else {
		emit("null")
	}
	emit(", \"present_after\": %t, \"record_after\": ", present_after)
	if present_after {
		emit("\"%s\"", hx(record_after))
	} else {
		emit("null")
	}
	emit(", \"root_before\": \"%s\", \"root_after\": \"%s\"", hx32(root_before), hx32(root_after))
	emit(", \"siblings_leaf_to_root\": ")
	emit_siblings(sibs[:])
	emit(", \"siblings_unchanged\": true, \"keys_touched\": 1}}")
}

OCCUPANCIES := []int{0, 1, 2, 3, 5, 8, 17, 64, 257}
BOUNDARY_BITS := []int{0, 1, 7, 8, 63, 64, 127, 128, 254, 255}
PROOF_OCCUPANCIES := []int{1, 2, 8, 64}
UPDATE_OCCUPANCIES := []int{1, 8, 64}

main :: proc() {
	canonical.tree_init()
	strings.builder_init(&out)
	r := Rng{s = TREE_V1_SEED}

	emit("{{\n")
	emit("  \"tier\": \"tree-v1-expansion\",\n")
	emit("  \"commitment_version\": \"%s\",\n", canonical.DOMAIN_WORLD_V1)
	emit(
		"  \"provenance\": \"generator-produced from protocol/canonical/tree.odin; the hand-derived tree-v1-constitutional tier pins the meaning and is never regenerated\",\n",
	)
	emit("  \"seed\": \"0x%x\",\n", TREE_V1_SEED)
	emit("  \"depth\": %d,\n", canonical.TREE_DEPTH)

	// --- occupancy across every domain -------------------------------------
	emit("  \"occupancy\": [\n")
	first := true
	for tag in ([]canonical.Domain_Tag{.Subject, .Blockmon, .Encounter, .Supply}) {
		occs := tag == .Supply ? []int{0, 1} : OCCUPANCIES
		for n in occs {
			if !first {
				emit(",\n")
			}
			first = false
			es := mk_entries(tag, n, &r)
			emit(
				"    {{\"tag\": %d, \"domain\": \"%s\", \"count\": %d, \"entries\": ",
				u8(tag),
				domain_name(tag),
				n,
			)
			emit_entries(es)
			emit(", \"domain_root\": \"%s\"}}", hx32(canonical.domain_root(tag, es)))
		}
	}
	emit("\n  ],\n")

	// --- bit-boundary families ---------------------------------------------
	emit("  \"bit_boundary\": [\n")
	for b, i in BOUNDARY_BITS {
		if i > 0 {
			emit(",\n")
		}
		base := rand_key(&r)
		other := base
		other[b / 8] ~= byte(1 << uint(7 - b % 8))
		es := make([]canonical.Tree_Entry, 2)
		es[0] = canonical.Tree_Entry {
			key    = base,
			record = mk_record(.Blockmon, base, &r),
		}
		es[1] = canonical.Tree_Entry {
			key    = other,
			record = mk_record(.Blockmon, other, &r),
		}
		slice.sort_by(es, key_less)
		emit(
			"    {{\"differing_bit\": %d, \"base_key\": \"%s\", \"flipped_key\": \"%s\", \"entries\": ",
			b,
			hx32(base),
			hx32(other),
		)
		emit_entries(es)
		emit(", \"domain_root\": \"%s\", \"inclusion\": ", hx32(canonical.domain_root(.Blockmon, es)))
		emit_proof(.Blockmon, es, base)
		emit(", \"absence\": ")
		emit_proof(.Blockmon, es, rand_key(&r))
		emit("}}")
	}
	emit("\n  ],\n")

	// --- inclusion and absence proofs at varied occupancy -------------------
	emit("  \"proofs\": [\n")
	first = true
	for tag in ([]canonical.Domain_Tag{.Subject, .Blockmon}) {
		for n in PROOF_OCCUPANCIES {
			es := mk_entries(tag, n, &r)
			if !first {
				emit(",\n")
			}
			first = false
			emit("    {{\"count\": %d, \"entries\": ", n)
			emit_entries(es)
			emit(", \"inclusion\": ")
			emit_proof(tag, es, es[0].key)
			emit(", \"absence\": ")
			emit_proof(tag, es, rand_key(&r))
			emit("}}")
		}
	}
	emit("\n  ],\n")

	// --- updates: the bounded authenticated path, one key at a time ---------
	// Subject records are empty, so a subject modify is not an update; supply is
	// a singleton, so its only updates are gaining and losing the one key.
	emit("  \"updates\": [\n")
	first = true
	for tag in ([]canonical.Domain_Tag{.Subject, .Blockmon, .Encounter}) {
		for kind in ([]Update_Kind{.Modify, .Insert, .Delete}) {
			if tag == .Subject && kind == .Modify {
				continue
			}
			for n in UPDATE_OCCUPANCIES {
				if !first {
					emit(",\n")
				}
				first = false
				emit_update(tag, kind, n, &r)
			}
		}
	}
	emit(",\n")
	emit_update(.Supply, .Insert, 0, &r)
	emit(",\n")
	emit_update(.Supply, .Delete, 1, &r)
	emit("\n  ],\n")

	// --- supply singleton ---------------------------------------------------
	// An economically valid pair: one capture success, so consumed and created
	// each rise by one while the epoch and envelope hold (protocol.md §10).
	sup_envelope := 1000 + next_u64(&r) % 1000
	sup_minted := 1 + next_u64(&r) % sup_envelope
	sup_consumed := next_u64(&r) % sup_minted
	sup_created := next_u64(&r) % (sup_consumed + 1)
	sup_epoch := next_u64(&r) % 8
	before_buf: [dynamic]byte
	be64(&before_buf, sup_epoch)
	be64(&before_buf, sup_envelope)
	be64(&before_buf, sup_minted)
	be64(&before_buf, sup_consumed)
	be64(&before_buf, sup_created)
	after_buf: [dynamic]byte
	be64(&after_buf, sup_epoch)
	be64(&after_buf, sup_envelope)
	be64(&after_buf, sup_minted)
	be64(&after_buf, sup_consumed + 1)
	be64(&after_buf, sup_created + 1)
	sup := []canonical.Tree_Entry {
		{key = canonical.supply_singleton_key(), record = before_buf[:]},
	}
	sup_root := canonical.domain_root(.Supply, sup)
	sup_after := after_buf[:]
	sup2 := []canonical.Tree_Entry{{key = sup[0].key, record = sup_after}}
	emit("  \"supply\": {{\"admissible_key\": \"%s\", \"entries\": ", hx32(canonical.supply_singleton_key()))
	emit_entries(sup)
	emit(", \"domain_root\": \"%s\", \"supply_commitment\": \"%s\"", hx32(sup_root), hx32(sup_root))
	emit(
		", \"record_after\": \"%s\", \"root_after\": \"%s\"",
		hx(sup_after),
		hx32(canonical.domain_root(.Supply, sup2)),
	)
	emit("},\n")

	// --- world commitments --------------------------------------------------
	emit("  \"world_commitments\": [\n")
	for n, i in ([]int{0, 1, 8}) {
		if i > 0 {
			emit(",\n")
		}
		s_es := mk_entries(.Subject, n, &r)
		b_es := mk_entries(.Blockmon, n, &r)
		e_es := mk_entries(.Encounter, n, &r)
		p_es := mk_entries(.Supply, n == 0 ? 0 : 1, &r)
		s_root := canonical.domain_root(.Subject, s_es)
		b_root := canonical.domain_root(.Blockmon, b_es)
		e_root := canonical.domain_root(.Encounter, e_es)
		p_root := canonical.domain_root(.Supply, p_es)
		wc := canonical.encode_world_commitment_v1(s_root, b_root, e_root, p_root)
		emit("    {{\"per_domain_count\": %d, \"state\": {{\"subject\": ", n)
		emit_entries(s_es)
		emit(", \"blockmon\": ")
		emit_entries(b_es)
		emit(", \"encounter\": ")
		emit_entries(e_es)
		emit(", \"supply\": ")
		emit_entries(p_es)
		emit("}}")
		emit(", \"subject_root\": \"%s\", \"blockmon_root\": \"%s\"", hx32(s_root), hx32(b_root))
		emit(", \"encounter_root\": \"%s\", \"supply_root\": \"%s\"", hx32(e_root), hx32(p_root))
		emit(", \"world_commitment_bytes\": \"%s\"", hx(wc[:]))
		emit(
			", \"world_root\": \"%s\"}}",
			hx32(canonical.world_commitment_v1(s_root, b_root, e_root, p_root)),
		)
	}
	emit("\n  ],\n")

	// --- rejection classes, exactly the two the spec assigns ----------------
	es := mk_entries(.Blockmon, 4, &r)
	root := canonical.domain_root(.Blockmon, es)
	bad := root
	bad[31] ~= 0x01
	emit("  \"rejections\": [\n")
	emit(
		"    {{\"class\": \"malformed\", \"kind\": \"sibling-count\", \"siblings_present\": %d, \"required\": %d}},\n",
		canonical.TREE_DEPTH - 1,
		canonical.TREE_DEPTH,
	)
	emit(
		"    {{\"class\": \"malformed\", \"kind\": \"unassigned-tag\", \"tag_bytes\": [0, 5], \"assigned_tags\": [1, 2, 3, 4]}},\n",
	)
	emit(
		"    {{\"class\": \"malformed\", \"kind\": \"record-width\", \"domain\": \"blockmon\", \"record_bytes\": \"%s\", \"required_width\": 96}},\n",
		hx(es[0].record[:len(es[0].record) - 1]),
	)
	emit(
		"    {{\"class\": \"malformed\", \"kind\": \"supply-key\", \"key\": \"%s\", \"admissible_key\": \"%s\"}},\n",
		hx32(rand_key(&r)),
		hx32(canonical.supply_singleton_key()),
	)
	// The identifier binding, malformed per CE §7: the record names one key while
	// the proof claims another.
	mismatch_key := rand_key(&r)
	mismatch_id := rand_key(&r)
	emit(
		"    {{\"class\": \"malformed\", \"kind\": \"record-identifier-mismatch\", \"tag\": %d, \"domain\": \"%s\", \"key\": \"%s\", \"record_identifier\": \"%s\", \"record_bytes\": \"%s\"}},\n",
		u8(canonical.Domain_Tag.Blockmon),
		domain_name(.Blockmon),
		hx32(mismatch_key),
		hx32(mismatch_id),
		hx(mk_record(.Blockmon, mismatch_id, &r)),
	)
	// Refusal cannot be shown by an accepted update, so both directions are
	// recorded: a claimed root the proof does not open, and an absence claimed
	// for a key the root commits.
	up_sibs: [canonical.TREE_DEPTH][32]byte
	canonical.tree_siblings(.Blockmon, es, es[0].key, &up_sibs)
	emit(
		"    {{\"class\": \"well-formed but invalid\", \"kind\": \"update-old-root-mismatch\", \"tag\": %d, \"domain\": \"%s\", \"key\": \"%s\", \"entries\": ",
		u8(canonical.Domain_Tag.Blockmon),
		domain_name(.Blockmon),
		hx32(es[0].key),
	)
	emit_entries(es)
	emit(", \"present_before\": true, \"record_before\": \"%s\"", hx(es[0].record))
	emit(", \"claimed_old_root\": \"%s\", \"actual_old_root\": \"%s\"", hx32(bad), hx32(root))
	emit(", \"siblings_leaf_to_root\": ")
	emit_siblings(up_sibs[:])
	emit("}},\n")
	emit(
		"    {{\"class\": \"well-formed but invalid\", \"kind\": \"update-false-absence\", \"tag\": %d, \"domain\": \"%s\", \"key\": \"%s\", \"entries\": ",
		u8(canonical.Domain_Tag.Blockmon),
		domain_name(.Blockmon),
		hx32(es[0].key),
	)
	emit_entries(es)
	emit(", \"present_before\": false, \"record_before\": null")
	emit(", \"claimed_old_root\": \"%s\", \"actual_old_root\": \"%s\"", hx32(root), hx32(root))
	emit(
		", \"absence_climbs_to\": \"%s\"",
		hx32(canonical.root_from_absence(es[0].key, up_sibs[:])),
	)
	emit(", \"siblings_leaf_to_root\": ")
	emit_siblings(up_sibs[:])
	emit("}},\n")
	emit(
		"    {{\"class\": \"well-formed but invalid\", \"kind\": \"domain-root-mismatch\", \"tag\": %d, \"domain\": \"%s\", \"entries\": ",
		u8(canonical.Domain_Tag.Blockmon),
		domain_name(.Blockmon),
	)
	emit_entries(es)
	emit(
		", \"claimed_domain_root\": \"%s\", \"recomputed_domain_root\": \"%s\"}},\n",
		hx32(bad),
		hx32(root),
	)
	transposed := canonical.encode_world_commitment_v1(root, bad, root, bad)
	correct := canonical.encode_world_commitment_v1(root, bad, bad, root)
	emit("    {{\"class\": \"well-formed but invalid\", \"kind\": \"wrong-commitment-position\"")
	emit(", \"correct_bytes\": \"%s\"", hx(correct[:]))
	emit(", \"transposed_bytes\": \"%s\"", hx(transposed[:]))
	emit(", \"transposition\": \"encounter_root and supply_root exchanged\"")
	emit(", \"transposed_world_root\": \"%s\"", hx32(canonical.protocol_hash(canonical.DOMAIN_WORLD_V1, transposed[:])))
	emit(", \"correct_world_root\": \"%s\"}}\n", hx32(canonical.protocol_hash(canonical.DOMAIN_WORLD_V1, correct[:])))
	emit("  ],\n")

	// --- Transition 1 under v1: authenticated access, both accounting models
	// From the kernel's control flow, independently of how it commits: the
	// concrete bound protocol.md §2 needs for the first transition.
	per_key :: 1 + canonical.TREE_DEPTH
	emit("  \"transition1_authenticated_access\": {{\n")
	emit("    \"accounting\": {{\n")
	emit(
		"      \"per_key_recomputation\": %d, \"per_key_recomputation_definition\": \"1 leaf hash + %d node hashes\",\n",
		per_key,
		canonical.TREE_DEPTH,
	)
	emit(
		"      \"world_commitment_hash\": 1, \"world_commitment_definition\": \"one %s hash over the 128-byte WorldCommitmentV1 encoding; the encoding itself is not a hash\",\n",
		canonical.DOMAIN_WORLD_V1,
	)
	emit(
		"      \"full_state_kernel\": \"holds the whole world, so an authenticated read costs no hashing and only writes recompute\",\n",
	)
	emit(
		"      \"stateless_verifier\": \"has no state, so each authenticated read costs one proof climb of %d hashes\"\n",
		per_key,
	)
	emit("    }},\n")
	emit(
		"    \"reads\": {{\"subject\": 1, \"encounter\": 1, \"supply\": 1, \"total\": 3, \"full_state_kernel_hashes\": 0, \"stateless_verify_hashes\": %d}},\n",
		3 * per_key,
	)
	emit(
		"    \"rejected\": {{\"writes\": [], \"total\": 0, \"write_recomputation_hashes\": 0, \"note\": \"state is byte-identical, so every root is unchanged\"}},\n",
	)
	emit(
		"    \"roll_failed\": {{\"writes\": [\"encounter:permit_id\", \"supply:singleton\"], \"total\": 2, \"write_recomputation_hashes\": %d}},\n",
		2 * per_key + 1,
	)
	emit(
		"    \"created\": {{\"writes\": [\"encounter:permit_id\", \"supply:singleton\", \"blockmon:creature_id\"], \"total\": 3, \"write_recomputation_hashes\": %d}},\n",
		3 * per_key + 1,
	)
	emit("    \"bound\": {{\n")
	emit("      \"max_keys_read\": 3, \"max_keys_written\": 3,\n")
	emit(
		"      \"max_write_recomputation_hashes\": %d, \"max_write_recomputation_formula\": \"3 * (1 + %d) + 1\",\n",
		3 * per_key + 1,
		canonical.TREE_DEPTH,
	)
	emit("      \"max_stateless_verify_hashes\": %d,\n", 3 * per_key)
	emit("      \"independent_of_state_size\": true\n")
	emit("    }}\n")
	emit("  }}\n")
	emit("}}\n")

	fmt.print(strings.to_string(out))
	os.exit(0)
}
