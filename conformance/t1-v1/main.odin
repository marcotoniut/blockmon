// Transition 1 under world/v1. The kernel must reproduce the hand-derived tier
// in conformance/vectors/g0a-t1-v1.json, whose roots were derived from
// canonical-encoding.md §§2, 3, 6, 7 before the kernel moved off the flat root.
//
// End to end: the scenario's own command, context and manifest are replayed
// through the kernel, and the transition's own output state is committed, so a
// passing run means the kernel both computes the right commitment and reaches
// the right state.
//
// Three oracles must agree on every scenario: the tier's hand-derived roots,
// the kernel's full derivation from state, and the bounded update path walking
// only the keys the touch contract names.
package t1_v1_check

import canonical "../../protocol/canonical"
import kernel "../../protocol/kernel"

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"

VECTORS :: "conformance/vectors/g0a-t1-v1.json"

failures := 0
passed := 0

fail :: proc(name: string, detail: string) {
	fmt.printfln("  FAIL %s: %s", name, detail)
	failures += 1
}

expect :: proc(name: string, detail: string, ok: bool) {
	if !ok {
		fail(name, detail)
	}
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

// Corpus integers are decimal strings, so no float ever touches a u64.
num :: proc(v: json.Value) -> u64 {
	out, ok := strconv.parse_u64(str(v))
	if !ok {
		fmt.printfln("not a decimal integer: %s", str(v))
		os.exit(1)
	}
	return out
}

unhex32 :: proc(s: string) -> [32]byte {
	raw, ok := hex.decode(transmute([]byte)s[2:])
	if !ok || len(raw) != 32 {
		fmt.printfln("not a 32-byte hex value: %s", s)
		os.exit(1)
	}
	out: [32]byte
	copy(out[:], raw)
	return out
}

world_from :: proc(state: json.Object) -> kernel.World {
	w: kernel.World
	for s in arr(state["subjects"]) {
		append(&w.subjects, unhex32(str(s)))
	}
	for b in arr(state["blockmon"]) {
		r := obj(b)
		append(
			&w.blockmon,
			kernel.Blockmon_Record {
				creature_id = unhex32(str(r["creature_id"])),
				owner = unhex32(str(r["owner"])),
				origin_permit = unhex32(str(r["origin_permit"])),
			},
		)
	}
	for p in arr(state["permits"]) {
		r := obj(p)
		append(
			&w.permits,
			kernel.Permit_Record {
				permit_id = unhex32(str(r["permit_id"])),
				subject = unhex32(str(r["subject"])),
				encounter_class = u8(r["encounter_class"].(json.Integer)),
				expiry_position = num(r["expiry_position"]),
				status = u8(r["status"].(json.Integer)),
			},
		)
	}
	s := obj(state["supply"])
	w.supply = kernel.Supply {
		epoch    = num(s["epoch"]),
		envelope = num(s["envelope"]),
		minted   = num(s["minted"]),
		consumed = num(s["consumed"]),
		created  = num(s["created"]),
	}
	return w
}

free_world :: proc(w: ^kernel.World) {
	delete(w.subjects)
	delete(w.blockmon)
	delete(w.permits)
}

tag_name :: proc(tag: canonical.Domain_Tag) -> string {
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

// The tier writes touched keys as "<domain>:<0x hex key>".
key_label :: proc(tag: canonical.Domain_Tag, key: [32]byte) -> string {
	k := key
	return fmt.tprintf("%s:0x%s", tag_name(tag), string(hex.encode(k[:], context.temp_allocator)))
}

// Third oracle. The tracked commitment starts from a full derivation of the
// pre-state, is advanced by the kernel's bounded path alone, and must land on
// the commitment the tier derived by hand. Only the shipped path runs here: a
// second copy of the walk in this checker would test itself.
check_bounded_update :: proc(
	name: string,
	before: ^kernel.World,
	after: ^kernel.World,
	cmd: kernel.Command,
	fx: kernel.Effects,
	want_root: [32]byte,
) {
	tracked := kernel.track_world(before)
	err := kernel.tracked_advance(&tracked, before, after, cmd, fx)
	expect(name, fmt.tprintf("bounded update applies (%v)", err), err == .None)
	expect(
		name,
		"bounded update reaches the tier commitment",
		kernel.tracked_root(&tracked) == want_root,
	)
}

main :: proc() {
	data, rerr := os.read_entire_file_from_path(VECTORS, context.allocator)
	if rerr != nil {
		fmt.printfln("cannot read %s", VECTORS)
		os.exit(1)
	}
	root, jerr := json.parse(data, json.Specification.JSON, true)
	if jerr != nil {
		fmt.printfln("cannot parse %s", VECTORS)
		os.exit(1)
	}
	doc := obj(root)
	expect("tier", "commitment version", str(doc["commitment_version"]) == "blockmon/world/v1")

	for raw in arr(doc["checks"]) {
		c := obj(raw)
		name := str(c["name"])
		before := failures

		input := world_from(obj(c["input_state"]))
		defer free_world(&input)
		recorded_output := world_from(obj(c["output_state"]))
		defer free_world(&recorded_output)

		cmd := obj(c["command"])
		ctxv := obj(c["context"])
		man := obj(c["manifest"])
		command := kernel.Command {
			subject   = unhex32(str(cmd["subject"])),
			permit_id = unhex32(str(cmd["permit_id"])),
		}
		kctx := kernel.Context {
			position      = num(ctxv["position"]),
			epoch         = num(ctxv["epoch"]),
			entropy_round = num(ctxv["entropy_round"]),
			entropy_value = unhex32(str(ctxv["entropy_value"])),
		}
		manifest := kernel.Manifest {
			round_period          = num(man["round_period"]),
			entropy_safety_margin = num(man["entropy_safety_margin"]),
			catch_rate_bp         = u32(num(man["catch_rate_bp"])),
		}

		produced, fx := kernel.transition(&input, command, kctx, &manifest)
		defer free_world(&produced)

		// The commitment the tier derived, on both sides.
		in_want := unhex32(str(obj(c["input"])["world_root"]))
		out_want := unhex32(str(obj(c["output"])["world_root"]))
		expect(name, "input world_root", kernel.world_root(&input) == in_want)
		expect(name, "recorded output world_root", kernel.world_root(&recorded_output) == out_want)

		// The kernel's own output, committed by the kernel.
		expect(name, "produced world_root", kernel.world_root(&produced) == out_want)

		// Effects, so a wrong state cannot hide behind a right root.
		want_fx := obj(c["effects"])
		expect(name, "outcome", u64(fx.outcome) == u64(want_fx["outcome"].(json.Integer)))
		if fx.outcome == kernel.OUTCOME_REJECTED {
			expect(
				name,
				"reject reason",
				u64(fx.reject_reason) == u64(want_fx["reject_reason"].(json.Integer)),
			)
			// Rejection purity, at the commitment: nothing recomputed, nothing moved.
			expect(name, "rejection leaves the commitment unchanged", in_want == out_want)
		} else {
			expect(name, "roll", fx.roll == num(want_fx["roll"]))
			if fx.outcome == kernel.OUTCOME_CREATED {
				expect(name, "creature", fx.creature == unhex32(str(want_fx["creature"])))
			}
		}

		// The touch contract of the amended protocol.md §2 bound, compared key
		// by key against the tier rather than the tier against itself.
		touched: [dynamic]kernel.Touched_Key
		defer delete(touched)
		kernel.t1_touched_keys(command, fx, &touched)
		recorded := arr(c["writes"])
		expect(name, "keys written", len(touched) == len(recorded))
		if len(touched) == len(recorded) {
			for t, i in touched {
				expect(
					name,
					fmt.tprintf("write %d matches the tier", i),
					key_label(t.tag, t.key) == str(recorded[i]),
				)
			}
		}

		// Third oracle: the bounded path must land on the tier's commitment.
		check_bounded_update(name, &input, &produced, command, fx, out_want)

		if failures == before {
			passed += 1
			fmt.printfln("  ok   %s", name)
		}
	}

	total := len(arr(doc["checks"]))
	fmt.printfln("T1 v1 constitutional gate: %d/%d scenarios reproduced", passed, total)
	if failures > 0 || passed != total {
		os.exit(1)
	}
}
