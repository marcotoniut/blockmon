package kernel

import "core:slice"
import "core:testing"

SUBJECT_A :: [32]byte{0 ..= 31 = 0xAA}
SUBJECT_C :: [32]byte{0 ..= 31 = 0xCC}
PERMIT_B :: [32]byte{0 ..= 31 = 0xBB}
ENTROPY_SUCCESS :: [32]byte{0 ..= 31 = 0x01} // roll 2114 < 2500
ENTROPY_FAIL :: [32]byte{0 ..= 31 = 0x00} // roll 3628

fill :: proc(b: byte) -> (out: [32]byte) {
	for i in 0 ..< 32 {
		out[i] = b
	}
	return
}

test_manifest :: proc() -> Manifest {
	return Manifest{round_period = 32, entropy_safety_margin = 2, catch_rate_bp = 2500}
}

// position 100, round_period 32, margin 2 -> assigned round 6
test_ctx :: proc(entropy: [32]byte) -> Context {
	return Context{position = 100, epoch = 7, entropy_round = 6, entropy_value = entropy}
}

test_world :: proc() -> World {
	w: World
	append(&w.subjects, SUBJECT_A, SUBJECT_C)
	append(&w.permits, Permit_Record{PERMIT_B, SUBJECT_A, ENCOUNTER_COMMON, 1000, PERMIT_RESERVED})
	w.supply = Supply{epoch = 7, envelope = 100, minted = 10, consumed = 0, created = 0}
	return w
}

test_cmd :: proc() -> Command {
	return Command{subject = SUBJECT_A, permit_id = PERMIT_B}
}

expect_rejected :: proc(t: ^testing.T, w: ^World, cmd: Command, ctx: Context, m: ^Manifest, reason: u8) {
	prev_bytes := encode_world(w)
	defer delete(prev_bytes)
	next, fx := transition(w, cmd, ctx, m)
	defer destroy_world(&next)
	testing.expect_value(t, fx.outcome, OUTCOME_REJECTED)
	testing.expect_value(t, fx.reject_reason, reason)
	next_bytes := encode_world(&next)
	defer delete(next_bytes)
	testing.expect(t, slice.equal(prev_bytes[:], next_bytes[:]), "rejection must not mutate state")
}

@(test)
capture_success :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	next, fx := transition(&w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m)
	defer destroy_world(&next)

	testing.expect_value(t, fx.outcome, OUTCOME_CREATED)
	testing.expect_value(t, fx.roll, u64(2114))
	testing.expect_value(t, fx.creature, creature_id_from_permit(PERMIT_B))
	// value creation only by consuming permit (c) + capability (b): both spent
	testing.expect_value(t, next.permits[0].status, PERMIT_CONSUMED)
	testing.expect_value(t, next.supply.consumed, u64(1))
	testing.expect_value(t, next.supply.created, u64(1))
	testing.expect_value(t, len(next.blockmon), 1)
	testing.expect_value(t, next.blockmon[0].owner, SUBJECT_A) // exactly one owner
	testing.expect_value(t, next.blockmon[0].origin_permit, PERMIT_B)
	testing.expect_value(t, validate_world(&next), Validity.Ok) // conservation identities hold
	// input state untouched by the transition (pure function)
	testing.expect_value(t, w.permits[0].status, PERMIT_RESERVED)
	testing.expect_value(t, w.supply.consumed, u64(0))
}

@(test)
capture_roll_fails_consume_on_attempt :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	next, fx := transition(&w, test_cmd(), test_ctx(ENTROPY_FAIL), &m)
	defer destroy_world(&next)

	testing.expect_value(t, fx.outcome, OUTCOME_ROLL_FAILED)
	testing.expect_value(t, fx.roll, u64(3628))
	// consume-on-attempt: permit and capability spent, nothing created
	testing.expect_value(t, next.permits[0].status, PERMIT_CONSUMED)
	testing.expect_value(t, next.supply.consumed, u64(1))
	testing.expect_value(t, next.supply.created, u64(0))
	testing.expect_value(t, len(next.blockmon), 0)
	testing.expect_value(t, validate_world(&next), Validity.Ok)
}

@(test)
permit_reuse_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	next, _ := transition(&w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m)
	defer destroy_world(&next)
	// second attempt against the consumed permit: retry needs fresh authorisation
	expect_rejected(t, &next, test_cmd(), test_ctx(ENTROPY_FAIL), &m, REJECT_PERMIT_NOT_RESERVED)
}

@(test)
unknown_subject_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	cmd := Command{subject = fill(0xEE), permit_id = PERMIT_B}
	expect_rejected(t, &w, cmd, test_ctx(ENTROPY_SUCCESS), &m, REJECT_UNKNOWN_SUBJECT)
}

@(test)
unknown_permit_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	cmd := Command{subject = SUBJECT_A, permit_id = fill(0xEE)}
	expect_rejected(t, &w, cmd, test_ctx(ENTROPY_SUCCESS), &m, REJECT_UNKNOWN_PERMIT)
}

@(test)
foreign_permit_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	cmd := Command{subject = SUBJECT_C, permit_id = PERMIT_B} // C exists, permit is A's
	expect_rejected(t, &w, cmd, test_ctx(ENTROPY_SUCCESS), &m, REJECT_WRONG_SUBJECT)
}

@(test)
expired_permit_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	w.permits[0].expiry_position = 100 // exclusive bound: position 100 is expired
	m := test_manifest()
	expect_rejected(t, &w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m, REJECT_PERMIT_EXPIRED)
}

@(test)
capability_exhaustion_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	w.supply.consumed = 10 // == minted: pool exhausted; permit must survive
	m := test_manifest()
	expect_rejected(t, &w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m, REJECT_NO_CAPABILITY)
}

@(test)
entropy_round_mismatch_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	ctx := test_ctx(ENTROPY_SUCCESS)
	ctx.entropy_round = 5 // choosing a round is exactly what §9 forbids
	expect_rejected(t, &w, test_cmd(), ctx, &m, REJECT_ENTROPY_MISMATCH)
}

@(test)
wrong_epoch_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	ctx := test_ctx(ENTROPY_SUCCESS)
	ctx.epoch = 8 // capabilities are epoch-scoped
	expect_rejected(t, &w, test_cmd(), ctx, &m, REJECT_WRONG_EPOCH)
}

@(test)
invalid_state_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	w.supply.created = 5 // created > consumed: conservation violation in input
	m := test_manifest()
	expect_rejected(t, &w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m, REJECT_INVALID_STATE)
}

@(test)
zero_round_period_rejected :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	m.round_period = 0 // invalid manifest input: defined rejection, never a crash
	expect_rejected(t, &w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m, REJECT_INVALID_STATE)
}

@(test)
unsorted_world_invalid :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.subjects, SUBJECT_C, SUBJECT_A) // descending
	testing.expect_value(t, validate_world(&w), Validity.Unsorted_Subjects)
}

// §7: domain state is a keyed mapping, so the commitment cannot depend on the
// order the representation happens to hold. world_root is also called on states
// validate_world rejects, and an unsorted slice must not produce a different
// well-formed root.
@(test)
world_root_order_independent :: proc(t: ^testing.T) {
	sorted: World
	defer destroy_world(&sorted)
	append(&sorted.subjects, SUBJECT_A, SUBJECT_C)
	append(
		&sorted.blockmon,
		Blockmon_Record{fill(0x11), SUBJECT_A, PERMIT_B},
		Blockmon_Record{fill(0x22), SUBJECT_C, PERMIT_B},
	)
	append(
		&sorted.permits,
		Permit_Record{fill(0x33), SUBJECT_A, ENCOUNTER_COMMON, 1000, PERMIT_RESERVED},
		Permit_Record{fill(0x44), SUBJECT_C, ENCOUNTER_COMMON, 1000, PERMIT_RESERVED},
	)
	// extant == created, and the two permits above are still reserved
	sorted.supply = Supply{epoch = 7, envelope = 100, minted = 10, consumed = 2, created = 2}

	shuffled: World
	defer destroy_world(&shuffled)
	append(&shuffled.subjects, SUBJECT_C, SUBJECT_A)
	append(&shuffled.blockmon, sorted.blockmon[1], sorted.blockmon[0])
	append(&shuffled.permits, sorted.permits[1], sorted.permits[0])
	shuffled.supply = sorted.supply

	testing.expect_value(t, validate_world(&sorted), Validity.Ok)
	testing.expect(t, validate_world(&shuffled) != Validity.Ok, "shuffled state is not valid input")
	testing.expect_value(t, world_root(&shuffled), world_root(&sorted))
}

// The bounded path must reach what the full derivation reaches, and must refuse
// to advance a commitment that does not match the state it claims to commit.
@(test)
tracked_commitment_follows_full_derivation :: proc(t: ^testing.T) {
	entropies := [?][32]byte{ENTROPY_SUCCESS, ENTROPY_FAIL}
	for e in entropies {
		w := test_world()
		defer destroy_world(&w)
		m := test_manifest()
		tracked := track_world(&w)
		testing.expect_value(t, tracked_root(&tracked), world_root(&w))

		next, fx := transition(&w, test_cmd(), test_ctx(e), &m)
		defer destroy_world(&next)
		testing.expect(t, fx.outcome != OUTCOME_REJECTED, "fixture must be accepted")
		testing.expect_value(t, tracked_advance(&tracked, &w, &next, test_cmd(), fx), Track_Error.None)
		testing.expect_value(t, tracked_root(&tracked), world_root(&next))
	}
}

@(test)
tracked_commitment_still_after_rejection :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	w.permits[0].status = PERMIT_CONSUMED // already spent: rejected, writes nothing
	m := test_manifest()
	tracked := track_world(&w)
	before := tracked_root(&tracked)

	next, fx := transition(&w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m)
	defer destroy_world(&next)
	testing.expect_value(t, fx.outcome, OUTCOME_REJECTED)
	testing.expect_value(t, tracked_advance(&tracked, &w, &next, test_cmd(), fx), Track_Error.None)
	testing.expect_value(t, tracked_root(&tracked), before)
	testing.expect_value(t, tracked_root(&tracked), world_root(&next))
}

@(test)
tracked_commitment_refuses_to_advance_when_drifted :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	tracked := track_world(&w)
	tracked.encounter_root[31] ~= 0x01 // one bit of drift in a touched domain

	next, fx := transition(&w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m)
	defer destroy_world(&next)
	testing.expect_value(
		t,
		tracked_advance(&tracked, &w, &next, test_cmd(), fx),
		Track_Error.Old_Root_Mismatch,
	)
}

// Two keys of one domain would need the tree the first update leaves behind.
// Transition 1 never asks for it, so the guard is reached directly.
@(test)
tracked_commitment_refuses_two_keys_in_one_domain :: proc(t: ^testing.T) {
	w := test_world()
	defer destroy_world(&w)
	m := test_manifest()
	tracked := track_world(&w)

	next, _ := transition(&w, test_cmd(), test_ctx(ENTROPY_SUCCESS), &m)
	defer destroy_world(&next)
	twice := [?]Touched_Key {
		{tag = .Blockmon, key = creature_id_from_permit(PERMIT_B)},
		{tag = .Blockmon, key = fill(0x77)},
	}
	before := tracked
	testing.expect_value(
		t,
		tracked_advance_keys(&tracked, &w, &next, twice[:]),
		Track_Error.Domain_Touched_Twice,
	)
	// The first key applied before the second was refused; a tracker that kept
	// that half-advance would anchor every later transition against a
	// commitment matching neither state.
	testing.expect_value(t, tracked, before)
}

@(test)
entropy_reveal_strictly_after_commitment :: proc(t: ^testing.T) {
	m := test_manifest()
	positions := [?]u64{0, 1, 31, 32, 33, 100, 1000, 1 << 40}
	for p in positions {
		r := assigned_round(p, &m)
		testing.expect(t, reveal_position(r, &m) > p, "assigned round must reveal after the command position")
	}
}

@(test)
transition_deterministic :: proc(t: ^testing.T) {
	m := test_manifest()
	entropies := [?][32]byte{ENTROPY_SUCCESS, ENTROPY_FAIL}
	for e in entropies {
		w1 := test_world()
		w2 := test_world()
		defer destroy_world(&w1)
		defer destroy_world(&w2)
		n1, f1 := transition(&w1, test_cmd(), test_ctx(e), &m)
		n2, f2 := transition(&w2, test_cmd(), test_ctx(e), &m)
		defer destroy_world(&n1)
		defer destroy_world(&n2)
		b1 := encode_world(&n1)
		b2 := encode_world(&n2)
		defer delete(b1)
		defer delete(b2)
		testing.expect(t, slice.equal(b1[:], b2[:]), "state bytes must be identical across runs")
		e1 := encode_effects(&f1)
		e2 := encode_effects(&f2)
		defer delete(e1)
		defer delete(e2)
		testing.expect(t, slice.equal(e1[:], e2[:]), "effects bytes must be identical across runs")
		t1 := make_transcript(&w1, &n1, test_cmd(), f1)
		t2 := make_transcript(&w2, &n2, test_cmd(), f2)
		testing.expect_value(t, transcript_hash(&t1), transcript_hash(&t2))
	}
}
