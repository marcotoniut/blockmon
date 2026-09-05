// v1 authenticated-tree constitutional gate. The Odin reference must reproduce
// every value in conformance/vectors/g0a-tree-v1.json byte for byte. Those
// vectors were hand-derived from canonical-encoding.md §7 before this code
// existed, so this program is checked against the prose, never the reverse.
package tree_v1_check

import canonical "../../protocol/canonical"

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"

VECTORS :: "conformance/vectors/g0a-tree-v1.json"

Empty_Case :: struct {
	name:  string,
	level: int,
}

failures := 0
passed := 0

fail :: proc(name: string, detail: string) {
	fmt.printfln("FAIL %s: %s", name, detail)
	failures += 1
}

expect :: proc(name: string, detail: string, ok: bool) {
	if !ok {
		fail(name, detail)
	}
}

unhex :: proc(s: string) -> []byte {
	if len(s) <= 2 {
		return nil
	}
	raw, ok := hex.decode(transmute([]byte)s[2:])
	if !ok {
		fmt.printfln("FAIL: %s is not hex", s)
		os.exit(1)
	}
	return raw
}

unhex32 :: proc(s: string) -> [32]byte {
	raw := unhex(s)
	if len(raw) != 32 {
		fmt.printfln("FAIL: %s is not 32 bytes", s)
		os.exit(1)
	}
	out: [32]byte
	copy(out[:], raw)
	return out
}

obj :: proc(v: json.Value) -> json.Object {
	return v.(json.Object)
}

arr :: proc(v: json.Value) -> json.Array {
	return v.(json.Array)
}

str :: proc(v: json.Value) -> string {
	return v.(json.String)
}

key_less :: proc(a: canonical.Tree_Entry, b: canonical.Tree_Entry) -> bool {
	for i in 0 ..< 32 {
		if a.key[i] != b.key[i] {
			return a.key[i] < b.key[i]
		}
	}
	return false
}

// Entries as the reference wants them: sorted strictly ascending by key.
entries_from :: proc(items: json.Array) -> []canonical.Tree_Entry {
	out := make([]canonical.Tree_Entry, len(items))
	for it, i in items {
		e := obj(it)
		out[i] = canonical.Tree_Entry {
			key    = unhex32(str(e["key"])),
			record = unhex(str(e["record_bytes"])),
		}
	}
	slice.sort_by(out, key_less)
	return out
}

siblings_from :: proc(items: json.Array) -> [][32]byte {
	out := make([][32]byte, len(items))
	for it, i in items {
		out[i] = unhex32(str(it))
	}
	return out
}

// Every recorded sibling must equal what the reference derives for that key.
check_siblings :: proc(
	name: string,
	tag: canonical.Domain_Tag,
	sorted: []canonical.Tree_Entry,
	key: [32]byte,
	recorded: [][32]byte,
) {
	derived: [canonical.TREE_DEPTH][32]byte
	canonical.tree_siblings(tag, sorted, key, &derived)
	for i in 0 ..< len(recorded) {
		if derived[i] != recorded[i] {
			fail(name, fmt.tprintf("sibling %d differs", i))
			return
		}
	}
}

tag_of :: proc(o: json.Object, fallback: canonical.Domain_Tag) -> canonical.Domain_Tag {
	v, ok := o["tag"]
	if !ok {
		return fallback
	}
	return canonical.Domain_Tag(u8(v.(json.Integer)))
}

// A proof block: verifies the leaf, the sibling sequence and the climb.
check_proof :: proc(name: string, o: json.Object, sorted: []canonical.Tree_Entry) {
	p := obj(o["proof"])
	tag := tag_of(p, tag_of(o, .Blockmon))
	key := unhex32(str(p["key"]))
	sibs := siblings_from(arr(p["siblings_leaf_to_root"]))
	want_root := unhex32(str(p["domain_root"]))
	present := p["present"].(json.Boolean)

	if present {
		record := unhex(str(p["record_bytes"]))
		expect(name, "leaf", canonical.leaf_hash(tag, key, record) == unhex32(str(p["leaf"])))
		if canonical.proof_wellformed(sibs) {
			expect(name, "root from proof", canonical.root_from_proof(tag, key, record, sibs) == want_root)
		}
	} else {
		expect(name, "absent leaf is empty[0]", unhex32(str(p["leaf"])) == canonical.empty_commitment(0))
		if canonical.proof_wellformed(sibs) {
			expect(name, "root from absence", canonical.root_from_absence(key, sibs) == want_root)
		}
	}
	if canonical.proof_wellformed(sibs) {
		check_siblings(name, tag, sorted, key, sibs)
		expect(name, "domain root", canonical.domain_root(tag, sorted) == want_root)
	}
}

main :: proc() {
	canonical.tree_init()

	data, rerr := os.read_entire_file_from_path(VECTORS, context.allocator)
	if rerr != nil {
		fmt.printfln("cannot read %s", VECTORS)
		os.exit(1)
	}
	root_value, err := json.parse(data, json.Specification.JSON, true)
	if err != nil {
		fmt.printfln("cannot parse %s", VECTORS)
		os.exit(1)
	}
	doc := obj(root_value)

	// Preamble: the derived empty commitments.
	ec := obj(doc["empty_constants"])
	empty_cases := []Empty_Case {
		{"empty_0", 0},
		{"empty_1", 1},
		{"empty_2", 2},
		{"empty_254", 254},
		{"empty_255", 255},
		{"empty_256", 256},
	}
	for ec_case in empty_cases {
		expect(
			"empty_constants",
			ec_case.name,
			canonical.empty_commitment(ec_case.level) == unhex32(str(ec[ec_case.name])),
		)
	}

	for raw in arr(doc["checks"]) {
		c := obj(raw)
		name := str(c["name"])
		before := failures

		switch name {
		case "empty-domain-root":
			want := unhex32(str(c["domain_root"]))
			expect(name, "empty root", canonical.empty_root() == want)
			expect(name, "domain root of no entries", canonical.domain_root(tag_of(c, .Subject), nil) == want)

		case "single-leaf", "divergence-bit-0", "divergence-bit-255":
			sorted := entries_from(arr(c["entries"]))
			tag := tag_of(c, .Blockmon)
			for it in arr(c["entries"]) {
				e := obj(it)
				got := canonical.leaf_hash(tag, unhex32(str(e["key"])), unhex(str(e["record_bytes"])))
				expect(name, "leaf", got == unhex32(str(e["leaf"])))
			}
			if dr, has := c["domain_root"]; has {
				expect(name, "domain root", canonical.domain_root(tag, sorted) == unhex32(str(dr)))
			}
			check_proof(name, c, sorted)

		case "same-record-different-keys":
			tag := tag_of(c, .Subject)
			sorted := entries_from(arr(c["entries"]))
			leaves: [dynamic][32]byte
			defer delete(leaves)
			for it in arr(c["entries"]) {
				e := obj(it)
				got := canonical.leaf_hash(tag, unhex32(str(e["key"])), unhex(str(e["record_bytes"])))
				expect(name, "leaf", got == unhex32(str(e["leaf"])))
				append(&leaves, got)
			}
			expect(name, "leaves differ", leaves[0] != leaves[1])
			expect(name, "domain root", canonical.domain_root(tag, sorted) == unhex32(str(c["domain_root"])))

		case "same-key-record-different-tags":
			key := unhex32(str(c["key"]))
			record := unhex(str(c["record_bytes"]))
			l2 := canonical.leaf_hash(.Blockmon, key, record)
			l3 := canonical.leaf_hash(.Encounter, key, record)
			expect(name, "leaf under tag 2", l2 == unhex32(str(c["leaf_tag_2"])))
			expect(name, "leaf under tag 3", l3 == unhex32(str(c["leaf_tag_3"])))
			expect(name, "leaves differ", l2 != l3)

		case "leaf-node-domain-separation":
			payload := unhex(str(c["payload"]))
			under_leaf := canonical.protocol_hash(canonical.DOMAIN_SMT_LEAF, payload)
			under_node := canonical.protocol_hash(canonical.DOMAIN_SMT_NODE, payload)
			expect(name, "leaf domain", under_leaf == unhex32(str(c["under_leaf_domain"])))
			expect(name, "node domain", under_node == unhex32(str(c["under_node_domain"])))
			expect(name, "differ", under_leaf != under_node)

		case "absence-unoccupied-key", "absence-adjacent-key":
			// The occupied set is the single-leaf tree; the vector's root must match it.
			single := single_leaf_entries(doc)
			check_proof(name, c, single)

		case "malformed-sibling-count":
			p := obj(c["proof"])
			sibs := siblings_from(arr(p["siblings_leaf_to_root"]))
			expect(name, "rejected as malformed", !canonical.proof_wellformed(sibs))
			expect(name, "class", str(c["rejection_class"]) == "malformed")

		case "malformed-record-trailing-byte":
			record := unhex(str(c["record_bytes"]))
			expect(name, "not a BlockmonRecord width", len(record) != 3 * 32)
			expect(name, "class", str(c["rejection_class"]) == "malformed")

		case "invalid-domain-root-mismatch":
			p := obj(c["proof"])
			sibs := siblings_from(arr(p["siblings_leaf_to_root"]))
			key := unhex32(str(p["key"]))
			record := unhex(str(p["record_bytes"]))
			got := canonical.root_from_proof(tag_of(p, .Blockmon), key, record, sibs)
			expect(name, "well formed", canonical.proof_wellformed(sibs))
			expect(name, "recomputed root", got == unhex32(str(c["recomputed_domain_root"])))
			expect(name, "differs from claim", got != unhex32(str(c["claimed_domain_root"])))
			expect(name, "class", str(c["rejection_class"]) == "well-formed but invalid")

		case "world-commitment":
			r := obj(c["domain_roots"])
			st := obj(c["state"])
			subjects: [dynamic]canonical.Tree_Entry
			defer delete(subjects)
			for it in arr(st["subject"]) {
				append(&subjects, canonical.Tree_Entry{key = unhex32(str(it))})
			}
			slice.sort_by(subjects[:], key_less)
			sup := obj(st["supply"])
			supply := []canonical.Tree_Entry {
				{key = unhex32(str(sup["key"])), record = unhex(str(sup["record_bytes"]))},
			}
			s_root := canonical.domain_root(.Subject, subjects[:])
			b_root := canonical.domain_root(.Blockmon, entries_from(arr(st["blockmon"])))
			e_root := canonical.domain_root(.Encounter, entries_from(arr(st["encounter"])))
			p_root := canonical.domain_root(.Supply, supply)
			expect(name, "subject_root", s_root == unhex32(str(r["subject_root"])))
			expect(name, "blockmon_root", b_root == unhex32(str(r["blockmon_root"])))
			expect(name, "encounter_root", e_root == unhex32(str(r["encounter_root"])))
			expect(name, "supply_root", p_root == unhex32(str(r["supply_root"])))
			wc := canonical.encode_world_commitment_v1(s_root, b_root, e_root, p_root)
			expect(name, "commitment bytes", slice.equal(wc[:], unhex(str(c["world_commitment_bytes"]))))
			expect(
				name,
				"world_root",
				canonical.world_commitment_v1(s_root, b_root, e_root, p_root) ==
				unhex32(str(c["world_root"])),
			)

		case "invalid-wrong-commitment-position":
			swapped := unhex(str(c["world_commitment_bytes"]))
			got := canonical.protocol_hash(canonical.DOMAIN_WORLD_V1, swapped)
			expect(name, "world_root of the swapped record", got == unhex32(str(c["world_root"])))
			expect(name, "differs from correct", got != unhex32(str(c["correct_world_root"])))
			expect(name, "class", str(c["rejection_class"]) == "well-formed but invalid")

		case "supply-singleton":
			e := obj(arr(c["entries"])[0])
			key := unhex32(str(e["key"]))
			record := unhex(str(e["record_bytes"]))
			expect(name, "singleton key", key == canonical.supply_singleton_key())
			expect(name, "leaf", canonical.leaf_hash(.Supply, key, record) == unhex32(str(e["leaf"])))
			entry := []canonical.Tree_Entry{{key = key, record = record}}
			root := canonical.domain_root(.Supply, entry)
			expect(name, "domain root", root == unhex32(str(c["domain_root"])))
			expect(name, "supply_commitment == supply_root", root == unhex32(str(c["supply_commitment"])))

		case "malformed-supply-key":
			expect(name, "inadmissible key", unhex32(str(c["key"])) != canonical.supply_singleton_key())
			expect(name, "class", str(c["rejection_class"]) == "malformed")

		case:
			fail(name, "no verification implemented for this check")
		}

		if failures == before {
			passed += 1
		}
	}

	total := len(arr(doc["checks"]))
	fmt.printfln("v1 tree constitutional gate: %d/%d checks reproduced", passed, total)
	if failures > 0 || passed != total {
		os.exit(1)
	}
}

// The occupied set the absence proofs are taken against.
single_leaf_entries :: proc(doc: json.Object) -> []canonical.Tree_Entry {
	for raw in arr(doc["checks"]) {
		c := obj(raw)
		if str(c["name"]) == "single-leaf" {
			return entries_from(arr(c["entries"]))
		}
	}
	fmt.println("single-leaf check missing")
	os.exit(1)
}
