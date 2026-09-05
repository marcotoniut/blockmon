// G0b: deterministic property/fuzz verification of the Transition 1 kernel
// (prototype-and-technology.md §3 G0, "0b hardening: ≥10⁶ fuzzed transitions").
//
// Not crash-fuzzing: every case asserts the constitutional properties from
// protocol.md §§2,5,6,10 with canonical bytes as the equality oracle.
// Worlds are generated RAW from the written invariants (not via kernel
// helpers), so validate_world is cross-checked rather than tautological.
//
// Reproduction: (seed, phase, case index / sequence index + step) replays any
// failure exactly; on failure the harness prints all of them plus the
// canonical hex of the offending inputs. Usage:
//   g0b-fuzz [seed] [singles] [sequences]
package g0b_fuzz

import canonical "../../protocol/canonical"
import kernel "../../protocol/kernel"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"

TRANSCRIPT_CASES_PER_PHASE :: 2000
transcripts_compared := 0
transcript_stride := u64(1)
transcript_seen := u64(0)

// Two full derivations per step, so this runs for the first steps of each
// phase. A tracked sequence runs to its end rather than abandoning a tracker
// mid-way, which makes the budget a floor. CI raises it; the summary reports
// the count reached.
TRACKED_DEFAULT :: 500
tracked_budget := u64(TRACKED_DEFAULT)
tracked_steps := u64(0)
tracked_steps_total := u64(0)
tracked_stride := u64(1)
tracked_seen := u64(0)

SEED_DEFAULT: u64 : 0xB10C0DE5EED
SINGLES_DEFAULT :: 1_000_000
SEQUENCES_DEFAULT :: 20_000
ID_STABILITY_CASES :: 200_000

// ---- deterministic PRNG (splitmix64; no OS randomness anywhere) ---------------

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

rand_below :: proc(r: ^Rng, n: u64) -> u64 {
	assert(n > 0)
	return next_u64(r) % n
}

rand_h32 :: proc(r: ^Rng) -> (out: [32]byte) {
	for i in 0 ..< 4 {
		v := next_u64(r)
		for j in 0 ..< 8 {
			out[i * 8 + j] = byte(v >> uint(56 - j * 8))
		}
	}
	return
}

// ---- failure reporting ----------------------------------------------------------

seed_global: u64
phase_global: string

// Per phase: a single budget is spent inside the first bulk phase.
// Stride sampling, not first-N: a first-N budget misses late-phase
// shapes.
enter_phase :: proc(name: string, t_stride: u64 = 1, k_stride: u64 = 1) {
	phase_global = name
	transcript_stride = max(1, t_stride)
	tracked_stride = max(1, k_stride)
	transcript_seen = 0
	tracked_seen = 0
	transcripts_compared = 0
	tracked_steps = 0
}
case_global: u64
step_global: int
fail_count := 0

fail :: proc(what: string, args: ..any) {
	fmt.eprintf("COUNTEREXAMPLE seed=%d phase=%s case=%d step=%d: ", seed_global, phase_global, case_global, step_global)
	fmt.eprintf(what, ..args)
	fmt.eprintln()
	fail_count += 1
	if fail_count > 20 {
		fmt.eprintln("too many failures; aborting")
		os.exit(1)
	}
}

dump_inputs :: proc(w: ^kernel.World, cmd: kernel.Command, ctx: kernel.Context, m: ^kernel.Manifest) {
	cmd, ctx := cmd, ctx
	if kernel.validate_world(w) == .Ok {
		wb := kernel.encode_world(w)
		fmt.eprintf("  world=%x\n", wb[:])
	}
	cb := kernel.encode_command(&cmd)
	fmt.eprintf("  command=%x\n  ctx={{pos=%d epoch=%d round=%d entropy=%x}}\n  manifest={{rp=%d margin=%d catch=%d}}\n",
		cb[:], ctx.position, ctx.epoch, ctx.entropy_round, ctx.entropy_value[:], m.round_period, m.entropy_safety_margin, m.catch_rate_bp)
}

// ---- raw generators (from the written invariants, not kernel constructors) -------

sorted_unique_ids :: proc(r: ^Rng, n: int) -> [dynamic][32]byte {
	out: [dynamic][32]byte
	for _ in 0 ..< n {
		append(&out, rand_h32(r)) // 256-bit ids: duplicate probability negligible
	}
	slice.sort_by(out[:], kernel.hash32_less)
	return out
}

// A valid world per canonical-encoding.md §6: sorted ids, supply satisfying
// envelope ≥ minted ≥ consumed ≥ created, extant == created.
gen_valid_world :: proc(r: ^Rng) -> kernel.World {
	w: kernel.World
	w.subjects = sorted_unique_ids(r, int(1 + rand_below(r, 4)))

	created := rand_below(r, 3)
	consumed := created + rand_below(r, 3)
	minted := consumed + rand_below(r, 5)
	envelope := minted + rand_below(r, 50)
	w.supply = kernel.Supply{
		epoch    = rand_below(r, 1000),
		envelope = envelope,
		minted   = minted,
		consumed = consumed,
		created  = created,
	}

	creature_ids := sorted_unique_ids(r, int(created))
	defer delete(creature_ids)
	for id in creature_ids {
		owner := w.subjects[rand_below(r, u64(len(w.subjects)))]
		append(&w.blockmon, kernel.Blockmon_Record{id, owner, rand_h32(r)})
	}

	permit_ids := sorted_unique_ids(r, int(1 + rand_below(r, 5)))
	defer delete(permit_ids)
	for id in permit_ids {
		status := kernel.PERMIT_RESERVED if rand_below(r, 4) > 0 else kernel.PERMIT_CONSUMED
		append(&w.permits, kernel.Permit_Record{
			id,
			w.subjects[rand_below(r, u64(len(w.subjects)))],
			kernel.ENCOUNTER_COMMON,
			1 + rand_below(r, 1 << 20),
			status,
		})
	}
	return w
}

gen_manifest :: proc(r: ^Rng) -> kernel.Manifest {
	catch: u32
	switch rand_below(r, 10) {
	case 0:
		catch = 0 // never captures
	case 1:
		catch = 10_000 // always captures
	case 2:
		catch = 12_345 // above the modulus: legal, always captures
	case:
		catch = u32(rand_below(r, 10_001))
	}
	return kernel.Manifest{
		round_period          = 1 + rand_below(r, 512),
		entropy_safety_margin = rand_below(r, 9),
		catch_rate_bp         = catch,
	}
}

reserved_permit_index :: proc(r: ^Rng, w: ^kernel.World) -> int {
	candidates: [dynamic]int
	defer delete(candidates)
	for &p, i in w.permits {
		if p.status == kernel.PERMIT_RESERVED {
			append(&candidates, i)
		}
	}
	if len(candidates) == 0 {
		return -1
	}
	return candidates[rand_below(r, u64(len(candidates)))]
}

// A fully valid (command, context) for the given reserved permit: correct
// epoch, correct assigned round, unexpired position.
gen_valid_attempt :: proc(r: ^Rng, w: ^kernel.World, pi: int, m: ^kernel.Manifest) -> (kernel.Command, kernel.Context) {
	p := w.permits[pi]
	position := rand_below(r, p.expiry_position) // < expiry (exclusive bound)
	return kernel.Command{subject = p.subject, permit_id = p.permit_id},
		kernel.Context{
			position      = position,
			epoch         = w.supply.epoch,
			entropy_round = kernel.assigned_round(position, m),
			entropy_value = rand_h32(r),
		}
}

// ---- oracles -------------------------------------------------------------------

world_equal :: proc(a, b: ^kernel.World) -> bool {
	if len(a.subjects) != len(b.subjects) || len(a.blockmon) != len(b.blockmon) || len(a.permits) != len(b.permits) {
		return false
	}
	for s, i in a.subjects {
		if s != b.subjects[i] {
			return false
		}
	}
	for x, i in a.blockmon {
		if x != b.blockmon[i] {
			return false
		}
	}
	for x, i in a.permits {
		if x != b.permits[i] {
			return false
		}
	}
	return a.supply == b.supply
}

// Spec-derived roll (canonical-encoding.md §6), computed from canonical
// primitives rather than by calling the kernel's helpers.
spec_roll :: proc(entropy: [32]byte, permit: [32]byte, mh: [32]byte) -> u64 {
	entropy, permit, mh := entropy, permit, mh
	buf: [dynamic]byte
	defer delete(buf)
	canonical.enc_hash32(&buf, entropy[:])
	canonical.enc_hash32(&buf, permit[:])
	canonical.enc_hash32(&buf, mh[:])
	seed := canonical.protocol_hash(canonical.DOMAIN_CAPTURE_ROLL, buf[:])
	v: u64
	for i in 0 ..< 8 {
		v = v << 8 | u64(seed[i])
	}
	return v % 10_000
}

Counts :: struct {
	created:     u64,
	roll_failed: u64,
	rejected:    [10]u64, // by reason
}

counts: Counts

// Assert every property that must hold for a single transition, given the
// expected rejection reason (0 = attempt must execute).
// Advanced by the bounded path alone, compared against a full derivation.
// Passing a tracker in carries it across a sequence, so drift accumulates.
check_tracked_step :: proc(
	before: ^kernel.World,
	after: ^kernel.World,
	cmd: kernel.Command,
	fx: kernel.Effects,
	carried: ^kernel.Tracked_Commitment = nil,
) {
	tracked := carried == nil ? kernel.track_world(before) : carried^
	was := kernel.tracked_root(&tracked)
	tracked_steps += 1
	tracked_steps_total += 1

	if err := kernel.tracked_advance(&tracked, before, after, cmd, fx); err != .None {
		fail("tracked advance refused: %v", err)
		dump_inputs(before, cmd, kernel.Context{}, &kernel.Manifest{})
		return
	}
	if fx.outcome == kernel.OUTCOME_REJECTED {
		if kernel.tracked_root(&tracked) != was {
			fail("rejection moved the tracked commitment")
		}
		if !world_equal(before, after) {
			fail("rejection moved the state")
		}
	}
	if kernel.tracked_root(&tracked) != kernel.world_root(after) {
		fail("tracked commitment != full derivation")
		dump_inputs(before, cmd, kernel.Context{}, &kernel.Manifest{})
	}
	if carried != nil {
		carried^ = tracked
	}
}

check_transition :: proc(
	w: ^kernel.World,
	cmd: kernel.Command,
	ctx: kernel.Context,
	m: ^kernel.Manifest,
	expect_reason: u8,
	structural_only := false,
) {
	prev_valid := kernel.validate_world(w) == .Ok
	prev_bytes: [dynamic]byte
	if !structural_only {
		prev_bytes = kernel.encode_world(w)
	}

	next, fx := kernel.transition(w, cmd, ctx, m)

	// protocol.md §2, CE §7 Cost: the two paths agree, and a rejection moves
	// neither state nor commitment.
	if prev_valid {
		tracked_seen += 1
		if tracked_seen % tracked_stride == 0 && tracked_steps < tracked_budget {
			check_tracked_step(w, &next, cmd, fx)
		}
	}

	// totality: a defined semantic outcome, always
	if fx.outcome != kernel.OUTCOME_CREATED && fx.outcome != kernel.OUTCOME_ROLL_FAILED && fx.outcome != kernel.OUTCOME_REJECTED {
		fail("undefined outcome %d", fx.outcome)
		dump_inputs(w, cmd, ctx, m)
		return
	}

	// determinism: byte-identical replay
	next2, fx2 := kernel.transition(w, cmd, ctx, m)
	if !world_equal(&next, &next2) {
		fail("non-deterministic output state")
		dump_inputs(w, cmd, ctx, m)
	}
	fxb := kernel.encode_effects(&fx)
	fxb2 := kernel.encode_effects(&fx2)
	if !slice.equal(fxb[:], fxb2[:]) {
		fail("non-deterministic effects")
	}
	// A transcript carries two roots and a full derivation is O(state), so one
	// comparison costs four. State-level checks stay at full budget; full
	// transcript coverage returns when the bounded path replaces derivation.
	if !structural_only && prev_valid {
		transcript_seen += 1
	}
	if !structural_only &&
	   prev_valid &&
	   transcript_seen % transcript_stride == 0 &&
	   transcripts_compared < TRANSCRIPT_CASES_PER_PHASE {
		transcripts_compared += 1
		t1 := kernel.make_transcript(w, &next, cmd, fx)
		t2 := kernel.make_transcript(w, &next2, cmd, fx2)
		if kernel.transcript_hash(&t1) != kernel.transcript_hash(&t2) {
			fail("non-deterministic transcript hash")
		}
	}

	if expect_reason != 0 {
		if fx.outcome != kernel.OUTCOME_REJECTED || fx.reject_reason != expect_reason {
			fail("expected rejection %d, got outcome=%d reason=%d", expect_reason, fx.outcome, fx.reject_reason)
			dump_inputs(w, cmd, ctx, m)
		}
	}

	if fx.outcome == kernel.OUTCOME_REJECTED {
		counts.rejected[fx.reject_reason] += 1
		// rejection purity: canonical bytes unchanged, nothing consumed
		if structural_only {
			if !world_equal(w, &next) {
				fail("rejection mutated state (structural)")
			}
		} else {
			nb := kernel.encode_world(&next)
			if !slice.equal(prev_bytes[:], nb[:]) {
				fail("rejection mutated canonical state bytes, reason=%d", fx.reject_reason)
				dump_inputs(w, cmd, ctx, m)
			}
		}
	} else {
		// consume-on-attempt: exactly one capability, permit consumed
		if next.supply.consumed != w.supply.consumed + 1 {
			fail("consumed delta != 1 on attempt")
		}
		pi := -1
		for &p, i in next.permits {
			if p.permit_id == cmd.permit_id {
				pi = i
				break
			}
		}
		if pi < 0 || next.permits[pi].status != kernel.PERMIT_CONSUMED {
			fail("attempt did not consume the permit")
		}
		// conservation, as independent arithmetic (protocol.md §10)
		if next.supply.envelope != w.supply.envelope || next.supply.minted != w.supply.minted {
			fail("attempt altered envelope/minted")
		}
		mh := kernel.manifest_hash(m)
		roll := spec_roll(ctx.entropy_value, cmd.permit_id, mh)
		if fx.roll != roll {
			fail("roll %d differs from spec derivation %d", fx.roll, roll)
			dump_inputs(w, cmd, ctx, m)
		}
		should_create := roll < u64(m.catch_rate_bp)
		if should_create != (fx.outcome == kernel.OUTCOME_CREATED) {
			fail("outcome disagrees with spec roll comparison")
		}
		if fx.outcome == kernel.OUTCOME_CREATED {
			counts.created += 1
			if next.supply.created != w.supply.created + 1 || u64(len(next.blockmon)) != u64(len(w.blockmon)) + 1 {
				fail("creation accounting wrong")
			}
			permit_id := cmd.permit_id
			expected_id := canonical.protocol_hash(canonical.DOMAIN_CREATURE_ID, permit_id[:])
			if fx.creature != expected_id {
				fail("creature id differs from spec derivation")
			}
			found := false
			for &b in next.blockmon {
				if b.creature_id == expected_id {
					found = b.owner == cmd.subject && b.origin_permit == cmd.permit_id
					break
				}
			}
			if !found {
				fail("created creature missing or mis-owned")
			}
		} else {
			counts.roll_failed += 1
			// a failed roll must never mint
			if next.supply.created != w.supply.created || len(next.blockmon) != len(w.blockmon) {
				fail("failed roll created value")
			}
		}
		if v := kernel.validate_world(&next); v != .Ok {
			fail("post-state violates invariants: %v", v)
			dump_inputs(w, cmd, ctx, m)
		}
	}
}

// ---- phase 1: targeted single transitions ------------------------------------------

single_case :: proc(r: ^Rng) {
	w := gen_valid_world(r)
	m := gen_manifest(r)
	pi := reserved_permit_index(r, &w)
	if pi < 0 {
		w.permits[0].status = kernel.PERMIT_RESERVED
		pi = 0
	}
	cmd, ctx := gen_valid_attempt(r, &w, pi, &m)

	class := rand_below(r, 16)
	switch class {
	case 0:
		cmd.subject = rand_h32(r)
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_UNKNOWN_SUBJECT)
	case 1:
		cmd.permit_id = rand_h32(r)
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_UNKNOWN_PERMIT)
	case 2:
		w.permits[pi].status = kernel.PERMIT_CONSUMED
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_PERMIT_NOT_RESERVED)
	case 3:
		// another existing subject presents someone else's permit
		other := -1
		for s, i in w.subjects {
			if s != w.permits[pi].subject {
				other = i
				break
			}
		}
		if other >= 0 {
			cmd.subject = w.subjects[other]
			check_transition(&w, cmd, ctx, &m, kernel.REJECT_WRONG_SUBJECT)
		} else {
			check_transition(&w, cmd, ctx, &m, 0)
		}
	case 4:
		// expired: position at or past the exclusive bound
		ctx.position = w.permits[pi].expiry_position + rand_below(r, 3)
		ctx.entropy_round = kernel.assigned_round(ctx.position, &m)
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_PERMIT_EXPIRED)
	case 5:
		// capability exhaustion; created ≤ consumed must keep holding
		w.supply.consumed = w.supply.minted
		if w.supply.created > w.supply.consumed {
			w.supply.created = w.supply.consumed
			resize(&w.blockmon, int(w.supply.created))
		}
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_NO_CAPABILITY)
	case 6:
		// wrong entropy round (off by one, either side)
		ctx.entropy_round += 1 if rand_below(r, 2) == 0 else max(u64) - ctx.entropy_round + 1
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_ENTROPY_MISMATCH)
	case 7:
		ctx.epoch += 1 + rand_below(r, 5)
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_WRONG_EPOCH)
	case 8:
		// deliberately invalid world: current non-protocol boundary guard.
		// Asserted as present behaviour, not elevated to a protocol invariant.
		switch rand_below(r, 5) {
		case 0:
			if len(w.subjects) >= 2 {
				slice.swap(w.subjects[:], 0, 1)
			} else {
				w.supply.created = w.supply.consumed + 1
			}
		case 1:
			w.supply.created = w.supply.consumed + 1
		case 2:
			w.supply.consumed = w.supply.minted + 1
		case 3:
			w.supply.minted = w.supply.envelope + 1
		case 4:
			w.permits[0].status = 0 // invalid enum
		}
		if kernel.validate_world(&w) == .Ok {
			fail("corruption not detected by validate_world")
		}
		check_transition(&w, cmd, ctx, &m, kernel.REJECT_INVALID_STATE, structural_only = true)
	case:
		// valid attempt (roughly half of all cases)
		check_transition(&w, cmd, ctx, &m, 0)
	}
}

// ---- phase 2: stateful sequences ------------------------------------------------------

sequence_case :: proc(r: ^Rng) {
	w := gen_valid_world(r)
	m := gen_manifest(r)

	// independent model: permit availability + counters
	reserved: map[[32]byte]bool
	defer delete(reserved)
	for &p in w.permits {
		reserved[p.permit_id] = p.status == kernel.PERMIT_RESERVED
	}
	model_consumed := w.supply.consumed
	model_created := w.supply.created

	// Carried across the whole sequence: a tracker that is re-seeded each step
	// cannot show accumulated drift.
	tracked_seen += 1
	track := tracked_seen % tracked_stride == 0 && tracked_steps < tracked_budget
	tracked: kernel.Tracked_Commitment
	if track {
		tracked = kernel.track_world(&w)
	}

	steps := 16 + int(rand_below(r, 33))
	for step in 0 ..< steps {
		step_global = step
		class := rand_below(r, 10)

		if class == 9 {
			// discovery-boundary stand-in: a fresh permit enters the world
			id := rand_h32(r)
			p := kernel.Permit_Record{id, w.subjects[rand_below(r, u64(len(w.subjects)))], kernel.ENCOUNTER_COMMON, 1 + rand_below(r, 1 << 20), kernel.PERMIT_RESERVED}
			at := len(w.permits)
			for &q, i in w.permits {
				if kernel.hash32_less(id, q.permit_id) {
					at = i
					break
				}
			}
			pre := kernel.clone_world(&w)
			defer kernel.destroy_world(&pre)
			inject_at(&w.permits, at, p)
			reserved[id] = true
			if kernel.validate_world(&w) != .Ok {
				fail("world invalid after permit injection")
			}
			// An insert: no Transition 1 outcome produces one in this domain.
			if track {
				touched := [?]kernel.Touched_Key{{tag = .Encounter, key = id}}
				tracked_steps += 1
				tracked_steps_total += 1
				if err := kernel.tracked_advance_keys(&tracked, &pre, &w, touched[:]);
				   err != .None {
					fail("tracked advance refused on injection: %v", err)
				}
				if kernel.tracked_root(&tracked) != kernel.world_root(&w) {
					fail("tracked commitment != full derivation after injection")
				}
			}
			continue
		}

		pi := reserved_permit_index(r, &w)
		if pi < 0 {
			continue // nothing reserved; next step may inject
		}
		cmd, ctx := gen_valid_attempt(r, &w, pi, &m)
		expect: u8 = 0

		switch class {
		case 5:
			ctx.epoch += 7
			expect = kernel.REJECT_WRONG_EPOCH
		case 6:
			ctx.entropy_round += 3
			expect = kernel.REJECT_ENTROPY_MISMATCH
		case 7:
			ctx.position = w.permits[pi].expiry_position
			ctx.entropy_round = kernel.assigned_round(ctx.position, &m)
			expect = kernel.REJECT_PERMIT_EXPIRED
		case 8:
			// reuse: pick a consumed permit if one exists
			ci := -1
			for &p, i in w.permits {
				if p.status == kernel.PERMIT_CONSUMED {
					ci = i
					break
				}
			}
			if ci < 0 {
				// none consumed yet; run a valid attempt instead, subject to capacity
				if model_consumed >= w.supply.minted {
					expect = kernel.REJECT_NO_CAPABILITY
				}
			} else {
				cmd = kernel.Command{subject = w.permits[ci].subject, permit_id = w.permits[ci].permit_id}
				expect = kernel.REJECT_PERMIT_NOT_RESERVED
			}
		case:
			// valid attempt; capacity exhaustion arises organically
			if model_consumed >= w.supply.minted {
				expect = kernel.REJECT_NO_CAPABILITY
			}
		}

		next, fx := kernel.transition(&w, cmd, ctx, &m)

		if expect != 0 {
			if fx.outcome != kernel.OUTCOME_REJECTED || fx.reject_reason != expect {
				fail("sequence expected reason %d, got outcome=%d reason=%d", expect, fx.outcome, fx.reject_reason)
				dump_inputs(&w, cmd, ctx, &m)
			}
			if !world_equal(&w, &next) {
				fail("sequence rejection mutated state")
			}
		} else {
			if fx.outcome == kernel.OUTCOME_REJECTED {
				fail("sequence valid attempt rejected: reason=%d", fx.reject_reason)
				dump_inputs(&w, cmd, ctx, &m)
			} else {
				model_consumed += 1
				reserved[cmd.permit_id] = false
				if fx.outcome == kernel.OUTCOME_CREATED {
					model_created += 1
				}
			}
		}

		if track {
			check_tracked_step(&w, &next, cmd, fx, &tracked)
		}

		// This loop drives the kernel directly rather than through
		// check_transition, so without this the phase compares no transcript.
		transcript_seen += 1
		if transcript_seen % transcript_stride == 0 &&
		   transcripts_compared < TRANSCRIPT_CASES_PER_PHASE {
			transcripts_compared += 1
			next2, fx2 := kernel.transition(&w, cmd, ctx, &m)
			if !world_equal(&next, &next2) {
				fail("non-deterministic output state in sequence")
			}
			t1 := kernel.make_transcript(&w, &next, cmd, fx)
			t2 := kernel.make_transcript(&w, &next2, cmd, fx2)
			if kernel.transcript_hash(&t1) != kernel.transcript_hash(&t2) {
				fail("non-deterministic transcript hash in sequence")
			}
		}

		w = next

		// model vs kernel counter drift
		if w.supply.consumed != model_consumed || w.supply.created != model_created {
			fail("counter drift: model consumed=%d created=%d, kernel consumed=%d created=%d",
				model_consumed, model_created, w.supply.consumed, w.supply.created)
		}
	}
	if v := kernel.validate_world(&w); v != .Ok {
		fail("sequence final world invalid: %v", v)
	}
	// Drift persists, so the end of a sequence catches what the budget did not.
	if track && kernel.tracked_root(&tracked) != kernel.world_root(&w) {
		fail("tracked commitment != full derivation at end of sequence")
	}
	step_global = -1
}

// ---- phase 3: entropy boundary sweep ----------------------------------------------------

boundary_sweep :: proc() {
	periods := [?]u64{1, 2, 3, 32, 512, 4096}
	margins := [?]u64{0, 1, 8}
	for rp in periods {
		for mg in margins {
			m := kernel.Manifest{round_period = rp, entropy_safety_margin = mg, catch_rate_bp = 5000}
			positions := [?]u64{0, 1, rp - 1, rp, rp + 1, 7 * rp - 1, 7 * rp, 1 << 40, (1 << 40) + rp}
			for p in positions {
				r := kernel.assigned_round(p, &m)
				if kernel.reveal_position(r, &m) <= p {
					fail("reveal(assigned(%d)) = %d not after commitment (rp=%d margin=%d)", p, kernel.reveal_position(r, &m), rp, mg)
				}
			}
		}
	}
}

// ---- phase 4: creature id stability -------------------------------------------------------

id_stability :: proc(r: ^Rng) {
	seen: map[[32]byte][32]byte
	defer delete(seen)
	for i in 0 ..< ID_STABILITY_CASES {
		case_global = u64(i)
		permit := rand_h32(r)
		id := canonical.protocol_hash(canonical.DOMAIN_CREATURE_ID, permit[:])
		id2 := canonical.protocol_hash(canonical.DOMAIN_CREATURE_ID, permit[:])
		if id != id2 {
			fail("creature id not stable for identical permit")
		}
		if prev, hit := seen[id]; hit {
			if prev != permit {
				fail("creature id alias between distinct permits in corpus")
			}
		} else {
			seen[id] = permit
		}
	}
}

// ---- main ------------------------------------------------------------------------------------

main :: proc() {
	seed := SEED_DEFAULT
	singles := u64(SINGLES_DEFAULT)
	sequences := u64(SEQUENCES_DEFAULT)
	if len(os.args) > 1 {
		if v, ok := strconv.parse_u64(os.args[1]); ok {
			seed = v
		}
	}
	if len(os.args) > 2 {
		if v, ok := strconv.parse_u64(os.args[2]); ok {
			singles = v
		}
	}
	if len(os.args) > 3 {
		if v, ok := strconv.parse_u64(os.args[3]); ok {
			sequences = v
		}
	}
	if len(os.args) > 4 {
		if v, ok := strconv.parse_u64(os.args[4]); ok {
			tracked_budget = v
		}
	}
	seed_global = seed
	rng := Rng{s = seed}

	enter_phase("boundary")
	boundary_sweep()

	enter_phase("id-stability")
	id_stability(&rng)

	enter_phase(
		"single",
		singles / TRANSCRIPT_CASES_PER_PHASE,
		singles / max(1, tracked_budget),
	)
	step_global = -1
	for i in 0 ..< singles {
		case_global = i
		{
			context.allocator = context.temp_allocator
			single_case(&rng)
		}
		free_all(context.temp_allocator)
		if (i + 1) % 200_000 == 0 {
			fmt.eprintf("  single %d/%d\n", i + 1, singles)
		}
	}

	enter_phase(
		"sequence",
		sequences * 32 / TRANSCRIPT_CASES_PER_PHASE,
		sequences / max(1, tracked_budget / 32),
	)
	for i in 0 ..< sequences {
		case_global = i
		{
			context.allocator = context.temp_allocator
			sequence_case(&rng)
		}
		free_all(context.temp_allocator)
		if (i + 1) % 5000 == 0 {
			fmt.eprintf("  sequence %d/%d\n", i + 1, sequences)
		}
	}

	total_rejected: u64 = 0
	for c in counts.rejected {
		total_rejected += c
	}
	fmt.printf(
		"{{\"seed\": %d, \"singles\": %d, \"sequences\": %d, \"created\": %d, \"roll_failed\": %d, \"rejected_total\": %d, \"rejected_by_reason\": [",
		seed, singles, sequences, counts.created, counts.roll_failed, total_rejected,
	)
	for c, i in counts.rejected {
		fmt.printf("%s%d", ", " if i > 0 else "", c)
	}
	fmt.printf(
		"], \"tracked_steps\": %d, \"transcripts_compared\": %d, \"failures\": %d}}\n",
		tracked_steps_total,
		transcripts_compared,
		fail_count,
	)
	os.exit(1 if fail_count > 0 else 0)
}
