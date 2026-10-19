// The executable half of the bounded authenticated access clause in protocol.md
// §2 (register Q19). All other gates compare commitments, and a
// population-sized cost leaves those untouched. This is therefore the only
// place where that cost is observed.
package bounded_access

import canonical "../../protocol/canonical"
import kernel "../../protocol/kernel"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"

// Depth-only, so passing it is §2's property. Descent hits at most
// TREE_DEPTH levels, rebuild classifies two children per level, and a
// locator refile chains at most TREE_DEPTH hashes.
BOUND :: 4 * canonical.TREE_DEPTH

// Per touched key: one store read and one store write (each inside BOUND),
// apply_update's two climbs with their leaves, plus the leaf the write files.
KERNEL_HASHES_PER_KEY :: 2 * BOUND + 2 * (canonical.TREE_DEPTH + 1) + 1

failures := 0

fail :: proc(what: string, args: ..any) {
	fmt.eprintf("FAIL  ")
	fmt.eprintfln(what, ..args)
	failures += 1
}

// splitmix64: the literal seed below makes the whole harness reproducible.
Rng :: struct {
	s: u64,
}

next_u64 :: proc(r: ^Rng) -> u64 {
	r.s += 0x9E37_79B9_7F4A_7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

rand_h32 :: proc(r: ^Rng) -> (out: [32]byte) {
	for i in 0 ..< 32 {
		out[i] = byte(next_u64(r))
	}
	return
}

Measurement :: struct {
	population:      int,
	kernel_keys:     int,
	kernel_advance:  u64,
	kernel_store:    Store_Cost,
	kernel_transcript: u64,
	walk_siblings:   u64,
	walk_root:       u64,
	store_read:      Store_Cost,
	store_insert:    Store_Cost,
	store_modify:    Store_Cost,
	store_delete:    Store_Cost,
	// not per-operation: what it costs to have a store at all, in memory
	store_build:     Store_Cost,
}

Store_Cost :: struct {
	reads:  u64,
	writes: u64,
	hashes: u64,
}

store_snapshot :: proc(s: ^canonical.Path_Store) -> Store_Cost {
	return Store_Cost{reads = s.node_reads, writes = s.node_writes, hashes = s.hashes}
}

store_delta :: proc(before: Store_Cost, s: ^canonical.Path_Store) -> Store_Cost {
	return Store_Cost {
		reads = s.node_reads - before.reads,
		writes = s.node_writes - before.writes,
		hashes = s.hashes - before.hashes,
	}
}

cost_within :: proc(label: string, n: int, c: Store_Cost) {
	if c.reads > BOUND {
		fail("population %d: store %s made %d reads, bound is %d", n, label, c.reads, BOUND)
	}
	if c.writes > BOUND {
		fail("population %d: store %s made %d writes, bound is %d", n, label, c.writes, BOUND)
	}
	if c.hashes > BOUND {
		fail("population %d: store %s made %d hashes, bound is %d", n, label, c.hashes, BOUND)
	}
}

// ---- the world under test ---------------------------------------------------

// N blockmon and one reserved permit: everything except the permit is state the
// transition never reads. Valid kernel input per canonical-encoding.md §6.
build_world :: proc(n: int, r: ^Rng) -> kernel.World {
	w: kernel.World
	subject := rand_h32(r)
	append(&w.subjects, subject)

	for _ in 0 ..< n {
		id := rand_h32(r)
		append(&w.blockmon, kernel.Blockmon_Record{id, subject, rand_h32(r)})
	}
	slice.sort_by(w.blockmon[:], proc(a, b: kernel.Blockmon_Record) -> bool {
		return kernel.hash32_less(a.creature_id, b.creature_id)
	})

	append(
		&w.permits,
		kernel.Permit_Record {
			permit_id       = rand_h32(r),
			subject         = subject,
			encounter_class = kernel.ENCOUNTER_COMMON,
			expiry_position = 1 << 40,
			status          = kernel.PERMIT_RESERVED,
		},
	)

	w.supply = kernel.Supply {
		epoch    = 7,
		envelope = u64(n) + 1000,
		minted   = u64(n) + 1,
		consumed = u64(n),
		created  = u64(n),
	}
	return w
}

// ---- one population ----------------------------------------------------------

measure :: proc(n: int, seed: u64) -> Measurement {
	r := Rng{s = seed}
	m := Measurement{population = n}

	w := build_world(n, &r)
	defer kernel.destroy_world(&w)
	if v := kernel.validate_world(&w); v != .Ok {
		fail("population %d: constructed world is not valid kernel input: %v", n, v)
		return m
	}

	manifest := kernel.Manifest {
		round_period          = 1,
		entropy_safety_margin = 0,
		catch_rate_bp         = 10_000, // every roll captures: the maximal T1 touch set
	}
	cmd := kernel.Command{subject = w.subjects[0], permit_id = w.permits[0].permit_id}
	ctx := kernel.Context {
		position      = 1,
		epoch         = w.supply.epoch,
		entropy_round = kernel.assigned_round(1, &manifest),
		entropy_value = rand_h32(&r),
	}

	next, fx := kernel.transition(&w, cmd, ctx, &manifest)
	defer kernel.destroy_world(&next)
	if fx.outcome != kernel.OUTCOME_CREATED {
		fail("population %d: fixture did not produce a creation (outcome %d)", n, fx.outcome)
		return m
	}

	// ---- path 1: what Transition 1 executes --------------------------------
	tracked := kernel.track_world(&w)
	defer kernel.untrack(&tracked)
	touched: [dynamic]kernel.Touched_Key
	defer delete(touched)
	kernel.t1_touched_keys(cmd, fx, &touched)
	m.kernel_keys = len(touched)

	prev_root := kernel.tracked_root(&tracked)
	from := store_snapshot(&tracked.store)
	canonical.hash_calls_reset()
	if err := kernel.tracked_advance(&tracked, &w, &next, cmd, fx); err != .None {
		fail("population %d: tracked_advance refused: %v", n, err)
		return m
	}
	m.kernel_advance = canonical.hash_calls
	m.kernel_store = store_delta(from, &tracked.store)

	next_root := kernel.tracked_root(&tracked)
	if next_root != kernel.world_root(&next) {
		fail("population %d: tracked commitment disagrees with full derivation", n)
	}

	canonical.hash_calls_reset()
	_ = kernel.transcript_from_roots(prev_root, next_root, cmd, fx)
	m.kernel_transcript = canonical.hash_calls

	keys := u64(m.kernel_keys)
	if m.kernel_advance > keys * KERNEL_HASHES_PER_KEY {
		fail("population %d: kernel advance made %d hashes, bound is %d", n, m.kernel_advance, keys * KERNEL_HASHES_PER_KEY)
	}
	if m.kernel_store.reads > keys * 2 * BOUND {
		fail("population %d: kernel advance made %d store reads, bound is %d", n, m.kernel_store.reads, keys * 2 * BOUND)
	}
	if m.kernel_store.writes > keys * BOUND {
		fail("population %d: kernel advance made %d store writes, bound is %d", n, m.kernel_store.writes, keys * BOUND)
	}
	if m.kernel_transcript > 1 {
		fail("population %d: kernel transcript made %d hashes beyond its command hash", n, m.kernel_transcript - 1)
	}

	// ---- path 2: the walk primitives in isolation ---------------------------
	d := kernel.domain_entries(&w)
	defer kernel.free_domain_entries(&d)
	entries := kernel.domain_entries_for(&d, .Blockmon)
	target := fx.creature // the key the transition inserts

	sibs: [canonical.TREE_DEPTH][32]byte
	canonical.hash_calls_reset()
	canonical.tree_siblings(.Blockmon, entries, target, &sibs)
	m.walk_siblings = canonical.hash_calls

	canonical.hash_calls_reset()
	pre_root := canonical.domain_root(.Blockmon, entries)
	m.walk_root = canonical.hash_calls

	// ---- path 3: the store serving the same key ----------------------------
	store: canonical.Path_Store
	canonical.store_init(&store)
	defer canonical.store_destroy(&store)
	build_from := store_snapshot(&store)
	built := canonical.store_build(&store, .Blockmon, entries)
	m.store_build = store_delta(build_from, &store)
	if built != pre_root {
		fail("population %d: store build root differs from the derivation", n)
	}

	before := store_snapshot(&store)
	got: [canonical.TREE_DEPTH][32]byte
	_, present := canonical.store_read_path(&store, .Blockmon, target, &got)
	m.store_read = store_delta(before, &store)
	if present {
		fail("population %d: the key the transition creates already reads as present", n)
	}
	if got != sibs {
		fail("population %d: store absence proof differs from the walk", n)
	}

	da := kernel.domain_entries(&next)
	defer kernel.free_domain_entries(&da)
	after := kernel.domain_entries_for(&da, .Blockmon)
	rec, found := canonical.entry_at(after, target)
	if !found {
		fail("population %d: the created key is absent from the post-state", n)
		return m
	}
	leaf := canonical.leaf_hash(.Blockmon, target, rec)

	before = store_snapshot(&store)
	written := canonical.store_write(&store, .Blockmon, target, leaf, true)
	m.store_insert = store_delta(before, &store)
	if written != canonical.domain_root(.Blockmon, after) {
		fail("population %d: store root after insert differs from the derivation", n)
	}

	altered := make([]byte, len(rec))
	defer delete(altered)
	copy(altered, rec)
	altered[len(altered) - 1] ~= 0xff
	before = store_snapshot(&store)
	canonical.store_write(&store, .Blockmon, target, canonical.leaf_hash(.Blockmon, target, altered), true)
	m.store_modify = store_delta(before, &store)

	// Return to the pre-state root; the walk above already measured it.
	before = store_snapshot(&store)
	removed := canonical.store_write(&store, .Blockmon, target, {}, false)
	m.store_delete = store_delta(before, &store)
	if removed != pre_root {
		fail("population %d: store root after delete is not the pre-state root", n)
	}

	cost_within("read", n, m.store_read)
	cost_within("insert", n, m.store_insert)
	cost_within("modify", n, m.store_modify)
	cost_within("delete", n, m.store_delete)
	return m
}

// ---- report -------------------------------------------------------------------

SEED :: u64(0x_B0D1_9C05_7000)

main :: proc() {
	sizes := []int{1, 16, 256, 4096, 32768}
	if len(os.args) > 1 {
		parsed: [dynamic]int
		defer delete(parsed)
		for a in os.args[1:] {
			if v, ok := strconv.parse_int(a); ok && v >= 0 {
				append(&parsed, v)
			}
		}
		if len(parsed) > 0 {
			sizes = slice.clone(parsed[:])
		}
	}

	canonical.tree_ensure_init()

	results: [dynamic]Measurement
	for n in sizes {
		append(&results, measure(n, SEED))
	}

	fmt.println("Q19: per-operation cost against unrelated world size")
	fmt.println("one capture transition, three authenticated keys touched, hashes = protocol_hash calls")
	fmt.println()
	fmt.printfln(
		"%-9s | %-9s %-11s %-11s | %-10s %-10s | %s",
		"blockmon",
		"advance",
		"store r/w",
		"transcript",
		"siblings",
		"full root",
		"store per key, reads/writes/hashes",
	)
	fmt.printfln(
		"%-9s | %-34s | %-23s | %s",
		"",
		"KERNEL PATH",
		"WALK PRIMITIVES",
		"read       insert     modify     delete",
	)
	for m in results {
		fmt.printfln(
			"%-9s | %-9s %-11s %-11s | %-10s %-10s | %-10s %-10s %-10s %s",
			num(u64(m.population)),
			num(m.kernel_advance),
			fmt.tprintf("%d/%d", m.kernel_store.reads, m.kernel_store.writes),
			num(m.kernel_transcript),
			num(m.walk_siblings),
			num(m.walk_root),
			cost_str(m.store_read),
			cost_str(m.store_insert),
			cost_str(m.store_modify),
			cost_str(m.store_delete),
		)
	}

	fmt.println()
	fmt.println("not per-operation, so not gated: having a store at all (store_build, the kernel's genesis)")
	for m in results {
		fmt.printfln("  population %-9s %s", num(u64(m.population)), cost_str(m.store_build))
	}

	fmt.println()
	fmt.printfln("depth-only bound asserted per store operation, on every axis: %d", BOUND)
	fmt.printfln("and per kernel key: %d hashes, %d store reads, %d store writes", KERNEL_HASHES_PER_KEY, 2 * BOUND, BOUND)
	if len(results) >= 2 {
		lo, hi := results[0], results[len(results) - 1]
		kernel_bound := u64(hi.kernel_keys) * KERNEL_HASHES_PER_KEY
		classify("kernel tracked_advance", lo.population, hi.population, lo.kernel_advance, hi.kernel_advance, kernel_bound)
		classify("kernel transcript", lo.population, hi.population, lo.kernel_transcript, hi.kernel_transcript, BOUND)
		classify("walk tree_siblings", lo.population, hi.population, lo.walk_siblings, hi.walk_siblings, BOUND)
		classify("store read reads", lo.population, hi.population, lo.store_read.reads, hi.store_read.reads, BOUND)
		classify("store insert hashes", lo.population, hi.population, lo.store_insert.hashes, hi.store_insert.hashes, BOUND)
		classify("store delete hashes", lo.population, hi.population, lo.store_delete.hashes, hi.store_delete.hashes, BOUND)
		classify("store_build hashes", lo.population, hi.population, lo.store_build.hashes, hi.store_build.hashes, BOUND)
	}

	fmt.println()
	if failures == 0 {
		fmt.println("Q19 GATE PASS: the kernel's and the store's per-operation cost stayed inside a")
		fmt.println("               depth-only bound and reproduced a full derivation at every population")
	} else {
		fmt.printfln("Q19 GATE FAIL: %d violations", failures)
	}
	os.exit(1 if failures > 0 else 0)
}

// Odin's %-Nd zero-pads on the right, so widths are applied to strings only.
num :: proc(v: u64) -> string {
	return fmt.tprintf("%d", v)
}

cost_str :: proc(c: Store_Cost) -> string {
	return fmt.tprintf("%d/%d/%d", c.reads, c.writes, c.hashes)
}

// Three verdicts, because "does not depend on total state size" and "bounded by
// tree depth" are different properties and the store satisfies only the second:
// a key's branch depth grows with log(population), inside the depth ceiling.
classify :: proc(what: string, lo_n, hi_n: int, lo, hi: u64, bound: u64) {
	verdict := "FLAT"
	switch {
	case hi > bound:
		verdict = "UNBOUNDED IN POPULATION"
	case hi > lo * 2 + 8:
		verdict = "GROWS, WITHIN DEPTH BOUND"
	}
	fmt.printfln("  %-24s %s -> %s (population %s -> %s): %s", what, num(lo), num(hi), num(u64(lo_n)), num(u64(hi_n)), verdict)
}
