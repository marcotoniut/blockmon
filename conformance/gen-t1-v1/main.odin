// Reference-side generator for the Transition 1 expansion tier under
// blockmon/world/v1. Emits conformance/vectors/g0a-t1-v1-expansion.json.
// Authority: canonical-encoding.md §§6-7, protocol.md §§2,5,6,10.
//
// conformance/README.md and the corpus "records" field state what this tier
// records and omits. The omissions are invisible in this code: a value absent
// from every case leaves nothing to see.
package g0a_gen_t1_v1

import canonical "../../protocol/canonical"
import kernel "../../protocol/kernel"

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Fixed literal: no OS randomness, so the corpus is byte-identical every run.
// Any regeneration diff signals drift.
SEED :: u64(0x_71C0_DE5E_ED01)
ACCEPTED_CASES :: 128
CASES_PER_DEFECT :: 8

// ---- deterministic PRNG (splitmix64) ----------------------------------------

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

below :: proc(r: ^Rng, n: u64) -> u64 {
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

// ---- output -----------------------------------------------------------------

out: strings.Builder
first_case := true

emit :: proc(format: string, args: ..any) {
	fmt.sbprintf(&out, format, ..args)
}

hx :: proc(b: []byte) -> string {
	s, _ := hex.encode(b)
	return fmt.tprintf("0x%s", string(s))
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("gen-t1-v1: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

// ---- state construction -----------------------------------------------------

sorted_ids :: proc(r: ^Rng, n: int) -> [dynamic][32]byte {
	ids: [dynamic][32]byte
	for _ in 0 ..< n {
		append(&ids, rand_h32(r)) // 256-bit: collision probability negligible
	}
	slice.sort_by(ids[:], kernel.hash32_less)
	return ids
}

valid_world :: proc(r: ^Rng) -> kernel.World {
	w: kernel.World
	w.subjects = sorted_ids(r, int(1 + below(r, 4)))

	created := below(r, 4)
	consumed := created + below(r, 3)
	minted := consumed + 1 + below(r, 4) // consumed < minted, so capability remains
	envelope := minted + below(r, 40)
	w.supply = kernel.Supply {
		epoch    = below(r, 1000),
		envelope = envelope,
		minted   = minted,
		consumed = consumed,
		created  = created,
	}

	creatures := sorted_ids(r, int(created))
	defer delete(creatures)
	for id in creatures {
		owner := w.subjects[below(r, u64(len(w.subjects)))]
		append(&w.blockmon, kernel.Blockmon_Record{id, owner, rand_h32(r)})
	}

	permits := sorted_ids(r, int(1 + below(r, 5)))
	defer delete(permits)
	for id in permits {
		append(
			&w.permits,
			kernel.Permit_Record {
				permit_id       = id,
				subject         = w.subjects[below(r, u64(len(w.subjects)))],
				encounter_class = kernel.ENCOUNTER_COMMON,
				expiry_position = 1 + below(r, 1 << 20),
				status          = kernel.PERMIT_RESERVED,
			},
		)
	}
	return w
}

varied_manifest :: proc(r: ^Rng) -> kernel.Manifest {
	catch: u32
	switch below(r, 8) {
	case 0:
		catch = 0 // never captures
	case 1:
		catch = 10_000 // always captures
	case 2:
		catch = 12_345 // above the modulus: legal, always captures
	case 3:
		catch = 1
	case 4:
		catch = 9_999
	case:
		catch = u32(below(r, 10_001))
	}
	periods := [?]u64{1, 2, 3, 32, 512, 4096}
	margins := [?]u64{0, 1, 2, 8}
	return kernel.Manifest {
		round_period          = periods[below(r, u64(len(periods)))],
		entropy_safety_margin = margins[below(r, u64(len(margins)))],
		catch_rate_bp         = catch,
	}
}

valid_attempt :: proc(
	r: ^Rng,
	w: ^kernel.World,
	pi: int,
	m: ^kernel.Manifest,
) -> (
	kernel.Command,
	kernel.Context,
) {
	p := w.permits[pi]
	position := below(r, p.expiry_position) // < expiry, the exclusive bound
	return kernel.Command{subject = p.subject, permit_id = p.permit_id},
		kernel.Context {
			position = position,
			epoch = w.supply.epoch,
			entropy_round = kernel.assigned_round(position, m),
			entropy_value = rand_h32(r),
		}
}

// ---- one defect per reject reason, applied to an otherwise valid case --------

Defect :: enum {
	None,
	Invalid_State_Created,
	Invalid_State_Consumed,
	Invalid_State_Minted,
	Invalid_State_Extant,
	Invalid_State_Unsorted_Subjects,
	Invalid_State_Unsorted_Blockmon,
	Invalid_State_Unsorted_Permits,
	Invalid_State_Bad_Enum,
	Invalid_Manifest_Round_Period,
	Wrong_Epoch,
	Entropy_Mismatch_High,
	Entropy_Mismatch_Low,
	Unknown_Subject,
	Unknown_Permit,
	Permit_Not_Reserved,
	Wrong_Subject,
	Permit_Expired_At_Bound,
	Permit_Expired_Past_Bound,
	No_Capability,
}

defect_reason :: proc(d: Defect) -> u8 {
	switch d {
	case .None:
		return 0
	case .Invalid_State_Created,
	     .Invalid_State_Consumed,
	     .Invalid_State_Minted,
	     .Invalid_State_Extant,
	     .Invalid_State_Unsorted_Subjects,
	     .Invalid_State_Unsorted_Blockmon,
	     .Invalid_State_Unsorted_Permits,
	     .Invalid_State_Bad_Enum,
	     .Invalid_Manifest_Round_Period:
		return kernel.REJECT_INVALID_STATE
	case .Wrong_Epoch:
		return kernel.REJECT_WRONG_EPOCH
	case .Entropy_Mismatch_High, .Entropy_Mismatch_Low:
		return kernel.REJECT_ENTROPY_MISMATCH
	case .Unknown_Subject:
		return kernel.REJECT_UNKNOWN_SUBJECT
	case .Unknown_Permit:
		return kernel.REJECT_UNKNOWN_PERMIT
	case .Permit_Not_Reserved:
		return kernel.REJECT_PERMIT_NOT_RESERVED
	case .Wrong_Subject:
		return kernel.REJECT_WRONG_SUBJECT
	case .Permit_Expired_At_Bound, .Permit_Expired_Past_Bound:
		return kernel.REJECT_PERMIT_EXPIRED
	case .No_Capability:
		return kernel.REJECT_NO_CAPABILITY
	}
	return 0
}

// Returns false when the world cannot carry the defect, so the caller skips
// instead of emitting a case with a different reason.
apply_defect :: proc(
	d: Defect,
	w: ^kernel.World,
	cmd: ^kernel.Command,
	ctx: ^kernel.Context,
	m: ^kernel.Manifest,
	pi: int,
) -> bool {
	switch d {
	case .None:
	case .Invalid_State_Created:
		w.supply.created = w.supply.consumed + 1
	case .Invalid_State_Consumed:
		w.supply.consumed = w.supply.minted + 1
	case .Invalid_State_Minted:
		w.supply.minted = w.supply.envelope + 1
	case .Invalid_State_Extant:
		// extant == created, broken without touching the supply chain
		append(&w.blockmon, kernel.Blockmon_Record{[32]byte{0 ..= 31 = 0xFF}, cmd.subject, cmd.permit_id})
	case .Invalid_State_Unsorted_Subjects:
		if len(w.subjects) < 2 {
			return false
		}
		slice.swap(w.subjects[:], 0, 1)
	case .Invalid_State_Unsorted_Blockmon:
		if len(w.blockmon) < 2 {
			return false
		}
		slice.swap(w.blockmon[:], 0, 1)
	case .Invalid_State_Unsorted_Permits:
		if len(w.permits) < 2 {
			return false
		}
		slice.swap(w.permits[:], 0, 1)
	case .Invalid_State_Bad_Enum:
		w.permits[pi].status = 0 // unassigned discriminant
	case .Invalid_Manifest_Round_Period:
		m.round_period = 0
	case .Wrong_Epoch:
		ctx.epoch += 1
	case .Entropy_Mismatch_High:
		ctx.entropy_round += 1
	case .Entropy_Mismatch_Low:
		if ctx.entropy_round == 0 {
			return false
		}
		ctx.entropy_round -= 1
	case .Unknown_Subject:
		cmd.subject = [32]byte{0 ..= 31 = 0xEE}
	case .Unknown_Permit:
		cmd.permit_id = [32]byte{0 ..= 31 = 0xEE}
	case .Permit_Not_Reserved:
		w.permits[pi].status = kernel.PERMIT_CONSUMED
	case .Wrong_Subject:
		other := -1
		for s, i in w.subjects {
			if s != w.permits[pi].subject {
				other = i
				break
			}
		}
		if other < 0 {
			return false
		}
		cmd.subject = w.subjects[other]
	case .Permit_Expired_At_Bound:
		// §6: the bound is exclusive, so position == expiry is already expired
		ctx.position = w.permits[pi].expiry_position
		ctx.entropy_round = kernel.assigned_round(ctx.position, m)
	case .Permit_Expired_Past_Bound:
		ctx.position = w.permits[pi].expiry_position + 1
		ctx.entropy_round = kernel.assigned_round(ctx.position, m)
	case .No_Capability:
		w.supply.consumed = w.supply.minted
		if w.supply.created > w.supply.consumed {
			w.supply.created = w.supply.consumed
			resize(&w.blockmon, int(w.supply.created))
		}
	}
	return true
}

// CE §2: an unassigned enum discriminant MUST be rejected, so a state carrying
// one has no canonical encoding and therefore no commitment. That is a real
// outcome of §6's INVALID_STATE class, not a case to avoid: a second
// implementation must refuse it too rather than invent a root.
world_encodable :: proc(w: ^kernel.World) -> bool {
	for &p in w.permits {
		if p.encounter_class != kernel.ENCOUNTER_COMMON {
			return false
		}
		if p.status != kernel.PERMIT_RESERVED && p.status != kernel.PERMIT_CONSUMED {
			return false
		}
	}
	return true
}

// Field equality, for the states canonical bytes cannot describe.
world_equal :: proc(a: ^kernel.World, b: ^kernel.World) -> bool {
	if len(a.subjects) != len(b.subjects) ||
	   len(a.blockmon) != len(b.blockmon) ||
	   len(a.permits) != len(b.permits) {
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

// ---- self-checks ------------------------------------------------------------

// protocol.md §10 for the computed transition, §6 for rejection purity.
check_conservation :: proc(
	name: string,
	before: ^kernel.World,
	after: ^kernel.World,
	cmd: kernel.Command,
	fx: kernel.Effects,
) {
	if fx.outcome == kernel.OUTCOME_REJECTED {
		if !world_encodable(before) {
			if !world_equal(before, after) {
				die("%s: a rejection changed the state", name)
			}
			return
		}
		bb := kernel.encode_world(before)
		defer delete(bb)
		ab := kernel.encode_world(after)
		defer delete(ab)
		if !slice.equal(bb[:], ab[:]) {
			die("%s: a rejection changed the canonical state bytes", name)
		}
		return
	}

	if after.supply.consumed != before.supply.consumed + 1 {
		die("%s: an attempt did not consume exactly one capability", name)
	}
	if after.supply.envelope != before.supply.envelope ||
	   after.supply.minted != before.supply.minted {
		die("%s: an attempt altered the envelope or the minted count", name)
	}
	spent := false
	for &p in after.permits {
		if p.permit_id == cmd.permit_id && p.status == kernel.PERMIT_CONSUMED {
			spent = true
		}
	}
	if !spent {
		die("%s: an attempt did not consume the permit", name)
	}

	if fx.outcome == kernel.OUTCOME_CREATED {
		if after.supply.created != before.supply.created + 1 ||
		   len(after.blockmon) != len(before.blockmon) + 1 {
			die("%s: creation accounting is wrong", name)
		}
	} else if after.supply.created != before.supply.created ||
	   len(after.blockmon) != len(before.blockmon) {
		die("%s: a failed roll created value", name)
	}
	if v := kernel.validate_world(after); v != .Ok {
		die("%s: the post-state violates §6 valid input: %v", name, v)
	}
}

// The bounded path has to reach the commitment a full derivation reaches,
// otherwise the corpus will record roots only one of them can produce.
check_bounded_path :: proc(
	name: string,
	before: ^kernel.World,
	after: ^kernel.World,
	cmd: kernel.Command,
	fx: kernel.Effects,
) {
	if kernel.validate_world(before) != .Ok {
		return // no pre-state commitment to advance from
	}
	bounded_checked += 1
	tracked := kernel.track_world(before)
	defer kernel.untrack(&tracked)
	if err := kernel.tracked_advance(&tracked, before, after, cmd, fx); err != .None {
		die("%s: the bounded path refused to advance: %v", name, err)
	}
	if kernel.tracked_root(&tracked) != kernel.world_root(after) {
		die("%s: the bounded path and a full derivation disagree", name)
	}
}

// ---- semantic JSON ----------------------------------------------------------
// u64 fields are quoted so a reader never has to parse a JSON number
// wider than its double.

world_json :: proc(w: ^kernel.World) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "{{\"subjects\": [")
	for &s, i in w.subjects {
		fmt.sbprintf(&b, "%s\"%s\"", ", " if i > 0 else "", hx(s[:]))
	}
	fmt.sbprintf(&b, "], \"blockmon\": [")
	for &m, i in w.blockmon {
		r := m
		fmt.sbprintf(
			&b,
			"%s{{\"creature_id\": \"%s\", \"owner\": \"%s\", \"origin_permit\": \"%s\"}}",
			", " if i > 0 else "",
			hx(r.creature_id[:]),
			hx(r.owner[:]),
			hx(r.origin_permit[:]),
		)
	}
	fmt.sbprintf(&b, "], \"permits\": [")
	for &p, i in w.permits {
		r := p
		fmt.sbprintf(
			&b,
			"%s{{\"permit_id\": \"%s\", \"subject\": \"%s\", \"encounter_class\": %d, \"expiry_position\": \"%d\", \"status\": %d}}",
			", " if i > 0 else "",
			hx(r.permit_id[:]),
			hx(r.subject[:]),
			r.encounter_class,
			r.expiry_position,
			r.status,
		)
	}
	fmt.sbprintf(
		&b,
		"], \"supply\": {{\"epoch\": \"%d\", \"envelope\": \"%d\", \"minted\": \"%d\", \"consumed\": \"%d\", \"created\": \"%d\"}}}}",
		w.supply.epoch,
		w.supply.envelope,
		w.supply.minted,
		w.supply.consumed,
		w.supply.created,
	)
	return strings.to_string(b)
}

effects_json :: proc(fx: kernel.Effects) -> string {
	f := fx
	b := strings.builder_make()
	fmt.sbprintf(&b, "{{\"outcome\": %d", f.outcome)
	if f.outcome == kernel.OUTCOME_REJECTED {
		fmt.sbprintf(&b, ", \"reject_reason\": %d, \"roll\": null, \"creature\": null", f.reject_reason)
	} else {
		fmt.sbprintf(&b, ", \"reject_reason\": null, \"roll\": \"%d\"", f.roll)
		if f.outcome == kernel.OUTCOME_CREATED {
			fmt.sbprintf(&b, ", \"creature\": \"%s\"", hx(f.creature[:]))
		} else {
			fmt.sbprintf(&b, ", \"creature\": null")
		}
	}
	fmt.sbprintf(&b, "}}")
	return strings.to_string(b)
}

commitment_json :: proc(w: ^kernel.World) -> string {
	if !world_encodable(w) {
		return "null"
	}
	d := kernel.domain_entries(w)
	defer kernel.free_domain_entries(&d)
	s_root, b_root, e_root, p_root := kernel.domain_roots(&d)
	world := canonical.world_commitment_v1(s_root, b_root, e_root, p_root)
	return fmt.tprintf(
		"{{\"subject_root\": \"%s\", \"blockmon_root\": \"%s\", \"encounter_root\": \"%s\", \"supply_root\": \"%s\", \"world_root\": \"%s\"}}",
		hx(s_root[:]),
		hx(b_root[:]),
		hx(e_root[:]),
		hx(p_root[:]),
		hx(world[:]),
	)
}

// ---- one case ---------------------------------------------------------------

emitted := 0
by_outcome: [4]int
by_reason: [10]int
// An invalid pre-state has no commitment to advance, so that check skips those
// cases. Counted, because a skip nobody counts is a check nobody runs.
bounded_checked := 0

emit_case :: proc(
	name: string,
	w: ^kernel.World,
	cmd: kernel.Command,
	ctx: kernel.Context,
	m: ^kernel.Manifest,
	expect: u8,
) {
	next, fx := kernel.transition(w, cmd, ctx, m)
	defer kernel.destroy_world(&next)

	if expect == 0 && fx.outcome == kernel.OUTCOME_REJECTED {
		die("%s: expected an attempt, got rejection %d", name, fx.reject_reason)
	}
	if expect != 0 && (fx.outcome != kernel.OUTCOME_REJECTED || fx.reject_reason != expect) {
		die("%s: expected reason %d, got outcome %d reason %d", name, expect, fx.outcome, fx.reject_reason)
	}

	// Byte-identical replay, so a recorded value is not one run's accident.
	again, fx2 := kernel.transition(w, cmd, ctx, m)
	defer kernel.destroy_world(&again)
	e1 := kernel.encode_effects(&fx)
	defer delete(e1)
	e2 := kernel.encode_effects(&fx2)
	defer delete(e2)
	if !slice.equal(e1[:], e2[:]) || !world_equal(&next, &again) {
		die("%s: the transition is not deterministic", name)
	}
	if world_encodable(&next) && kernel.world_root(&next) != kernel.world_root(&again) {
		die("%s: the post-state commitment is not deterministic", name)
	}

	check_conservation(name, w, &next, cmd, fx)
	check_bounded_path(name, w, &next, cmd, fx)

	cmd, ctx := cmd, ctx
	mh := kernel.manifest_hash(m)
	ch := kernel.command_hash(&cmd)
	// TranscriptV0 carries both world roots, so a state without a commitment
	// has no transcript hash either.
	transcript := "null"
	if world_encodable(w) && world_encodable(&next) {
		tr := kernel.make_transcript(w, &next, cmd, fx)
		th := kernel.transcript_hash(&tr)
		transcript = fmt.tprintf("\"%s\"", hx(th[:]))
	}

	if !first_case {
		emit(",\n")
	}
	first_case = false
	emit("    {{\"name\": \"%s\"", name)
	emit(
		", \"manifest\": {{\"round_period\": \"%d\", \"entropy_safety_margin\": \"%d\", \"catch_rate_bp\": %d}}",
		m.round_period,
		m.entropy_safety_margin,
		m.catch_rate_bp,
	)
	emit(", \"manifest_hash\": \"%s\"", hx(mh[:]))
	emit(", \"input_state\": %s", world_json(w))
	emit(", \"input_commitment\": %s", commitment_json(w))
	emit(
		", \"command\": {{\"subject\": \"%s\", \"permit_id\": \"%s\"}}, \"command_hash\": \"%s\"",
		hx(cmd.subject[:]),
		hx(cmd.permit_id[:]),
		hx(ch[:]),
	)
	emit(
		", \"context\": {{\"position\": \"%d\", \"epoch\": \"%d\", \"entropy_round\": \"%d\", \"entropy_value\": \"%s\"}}",
		ctx.position,
		ctx.epoch,
		ctx.entropy_round,
		hx(ctx.entropy_value[:]),
	)
	emit(", \"effects\": %s", effects_json(fx))
	emit(", \"output_state\": %s", world_json(&next))
	emit(", \"output_commitment\": %s", commitment_json(&next))
	emit(", \"transcript_hash\": %s}}", transcript)

	emitted += 1
	by_outcome[fx.outcome] += 1
	if fx.outcome == kernel.OUTCOME_REJECTED {
		by_reason[fx.reject_reason] += 1
	}
}

// Chosen at random from the reserved permits: a command that always targets
// permits[0] never exercises a later position in the domain.
reserved_index :: proc(r: ^Rng, w: ^kernel.World) -> int {
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
	return candidates[below(r, u64(len(candidates)))]
}

// ---- the sweep --------------------------------------------------------------

// INVALID_STATE has nine variants and so nine times the cases: each is a
// distinct clause of §6's valid-input definition, not a repeat.
ALL_DEFECTS := [?]Defect {
	.Invalid_State_Created,
	.Invalid_State_Consumed,
	.Invalid_State_Minted,
	.Invalid_State_Extant,
	.Invalid_State_Unsorted_Subjects,
	.Invalid_State_Unsorted_Blockmon,
	.Invalid_State_Unsorted_Permits,
	.Invalid_State_Bad_Enum,
	.Invalid_Manifest_Round_Period,
	.Wrong_Epoch,
	.Entropy_Mismatch_High,
	.Entropy_Mismatch_Low,
	.Unknown_Subject,
	.Unknown_Permit,
	.Permit_Not_Reserved,
	.Wrong_Subject,
	.Permit_Expired_At_Bound,
	.Permit_Expired_Past_Bound,
	.No_Capability,
}

sweep_case :: proc(r: ^Rng, name: string, d: Defect) {
	w := valid_world(r)
	defer kernel.destroy_world(&w)
	m := varied_manifest(r)
	pi := reserved_index(r, &w)
	if pi < 0 {
		return
	}
	cmd, ctx := valid_attempt(r, &w, pi, &m)
	if !apply_defect(d, &w, &cmd, &ctx, &m, pi) {
		return
	}
	emit_case(name, &w, cmd, ctx, &m, defect_reason(d))
}

main :: proc() {
	canonical.tree_ensure_init()
	strings.builder_init(&out)
	r := Rng{s = SEED}

	emit("{{\n")
	emit("  \"tier\": \"t1-v1-expansion\",\n")
	emit("  \"commitment_version\": \"%s\",\n", canonical.DOMAIN_WORLD_V1)
	emit(
		"  \"provenance\": \"generator-produced from protocol/kernel; the hand-derived t1-v1-constitutional tier pins the meaning and is never regenerated\",\n",
	)
	emit(
		"  \"records\": \"inputs and protocol-visible commitments only: no sibling sequences, leaf hashes, capture seed, WorldCommitmentV1 preimage, record encodings or touched-key set, since §7 makes none of them part of a protocol object\",\n",
	)
	emit("  \"seed\": \"%s\",\n", fmt.tprintf("0x%x", SEED))
	emit("  \"cases\": [\n")

	for i in 0 ..< ACCEPTED_CASES {
		sweep_case(&r, fmt.tprintf("t1v1-attempt-%03d", i), .None)
	}
	for d in ALL_DEFECTS {
		for i in 0 ..< CASES_PER_DEFECT {
			sweep_case(&r, fmt.tprintf("t1v1-%v-%02d", d, i), d)
		}
	}

	// An empty blockmon domain and an empty-but-for-supply world are the
	// occupancy boundaries the sweep reaches only by chance.
	{
		w: kernel.World
		defer kernel.destroy_world(&w)
		subject := [32]byte{0 ..= 31 = 0x11}
		permit := [32]byte{0 ..= 31 = 0x22}
		append(&w.subjects, subject)
		append(
			&w.permits,
			kernel.Permit_Record{permit, subject, kernel.ENCOUNTER_COMMON, 1 << 30, kernel.PERMIT_RESERVED},
		)
		w.supply = kernel.Supply {
			epoch    = 1,
			envelope = 4,
			minted   = 2,
			consumed = 0,
			created  = 0,
		}
		m := kernel.Manifest {
			round_period          = 1,
			entropy_safety_margin = 0,
			catch_rate_bp         = 10_000,
		}
		cmd := kernel.Command{subject = subject, permit_id = permit}
		ctx := kernel.Context {
			position      = 1,
			epoch         = 1,
			entropy_round = kernel.assigned_round(1, &m),
			entropy_value = [32]byte{0 ..= 31 = 0x33},
		}
		emit_case("t1v1-boundary-empty-blockmon-created", &w, cmd, ctx, &m, 0)

		never := m
		never.catch_rate_bp = 0
		emit_case("t1v1-boundary-empty-blockmon-roll-failed", &w, cmd, ctx, &never, 0)
	}

	emit("\n  ],\n")
	emit(
		"  \"coverage\": {{\"cases\": %d, \"created\": %d, \"roll_failed\": %d, \"rejected\": %d, \"rejected_by_reason\": [",
		emitted,
		by_outcome[kernel.OUTCOME_CREATED],
		by_outcome[kernel.OUTCOME_ROLL_FAILED],
		by_outcome[kernel.OUTCOME_REJECTED],
	)
	for c, i in by_reason {
		emit("%s%d", ", " if i > 0 else "", c)
	}
	emit("]}}\n}}\n")

	// Missing outcome or reason means this is not the right tier; abort instead of shipping.
	if by_outcome[kernel.OUTCOME_CREATED] == 0 || by_outcome[kernel.OUTCOME_ROLL_FAILED] == 0 {
		die("both accepted outcomes must appear")
	}
	for reason in 1 ..= 9 {
		if by_reason[reason] == 0 {
			die("reject reason %d is not covered", reason)
		}
	}
	if bounded_checked == 0 {
		die("no case reached the bounded-path check")
	}

	fmt.print(strings.to_string(out))
}
