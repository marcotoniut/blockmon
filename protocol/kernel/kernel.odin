// Transition 1 kernel: permit consumption, assigned entropy, capture roll,
// capability accounting, creature creation, state commitment update.
//
// Authority: protocol.md §§2,5,6,10; trust-and-economy.md §2; architecture.md
// §§6,9; canonical-encoding.md §6 encodings.
//
// This transition is a pure function with no side effects. All
// state-affecting inputs are parameters. It does not read clocks, RNGs,
// filesystems, environments, or networks. Semantic failures are defined
// outcomes (totality, protocol.md §2); partial mutations are not possible. A
// rejected command returns the input state untouched.
package kernel

import canonical "../canonical"

// ---- enums (wire values; 0 invalid) -----------------------------------------

ENCOUNTER_COMMON: u8 : 1

PERMIT_RESERVED: u8 : 1
PERMIT_CONSUMED: u8 : 2

OUTCOME_CREATED: u8 : 1
OUTCOME_ROLL_FAILED: u8 : 2
OUTCOME_REJECTED: u8 : 3

REJECT_UNKNOWN_SUBJECT: u8 : 1
REJECT_UNKNOWN_PERMIT: u8 : 2
REJECT_PERMIT_NOT_RESERVED: u8 : 3
REJECT_WRONG_SUBJECT: u8 : 4
REJECT_PERMIT_EXPIRED: u8 : 5
REJECT_NO_CAPABILITY: u8 : 6
REJECT_ENTROPY_MISMATCH: u8 : 7
REJECT_WRONG_EPOCH: u8 : 8
REJECT_INVALID_STATE: u8 : 9 // kernel boundary guard, not protocol semantics

ROLL_MODULUS: u64 : 10_000 // basis points; catch_rate_bp is measured against this

// ---- state -------------------------------------------------------------------

Blockmon_Record :: struct {
	creature_id:   [32]byte,
	owner:         [32]byte,
	origin_permit: [32]byte,
}

Permit_Record :: struct {
	permit_id:       [32]byte,
	subject:         [32]byte,
	encounter_class: u8,
	expiry_position: u64, // canonical positions, exclusive bound (never wall-clock)
	status:          u8,
}

Supply :: struct {
	epoch:    u64,
	envelope: u64, // constitutional scheduled envelope for the capture class
	minted:   u64, // capabilities pre-minted this epoch (minting is not a T1 path)
	consumed: u64, // consume-on-attempt: success and failure both spend
	created:  u64, // creations ≤ consumed; extant == created (no exits in T1)
}

World :: struct {
	subjects: [dynamic][32]byte,        // sorted strictly ascending
	blockmon: [dynamic]Blockmon_Record, // sorted strictly ascending by creature_id
	permits:  [dynamic]Permit_Record,   // sorted strictly ascending by permit_id
	supply:   Supply,
}

Manifest :: struct {
	round_period:          u64, // > 0; entropy round r reveals at position r * round_period
	entropy_safety_margin: u64,
	catch_rate_bp:         u32, // ruleset constant for the single T1 encounter class
}

Context :: struct {
	position:      u64, // canonical sequencing position of the command
	epoch:         u64,
	entropy_round: u64,      // must equal assigned_round(position, manifest)
	entropy_value: [32]byte, // authenticated beacon output for that round
}

Command :: struct {
	subject:   [32]byte,
	permit_id: [32]byte,
}

Effects :: struct {
	outcome:       u8,
	reject_reason: u8, // meaningful iff outcome == REJECTED
	roll:          u64, // meaningful iff outcome != REJECTED
	creature:      [32]byte, // meaningful iff outcome == CREATED
}

Transcript :: struct {
	command_hash: [32]byte,
	prev_root:    [32]byte,
	next_root:    [32]byte,
	effects:      Effects,
}

// ---- ordering / validity -------------------------------------------------------

hash32_less :: proc(a, b: [32]byte) -> bool {
	for i in 0 ..< 32 {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

Validity :: enum {
	Ok,
	Unsorted_Subjects,
	Unsorted_Blockmon,
	Unsorted_Permits,
	Bad_Enum,
	Supply_Minted_Exceeds_Envelope,
	Supply_Consumed_Exceeds_Minted,
	Supply_Created_Exceeds_Consumed,
	Extant_Mismatch,
}

validate_world :: proc(w: ^World) -> Validity {
	for i in 1 ..< len(w.subjects) {
		if !hash32_less(w.subjects[i - 1], w.subjects[i]) {
			return .Unsorted_Subjects
		}
	}
	for i in 1 ..< len(w.blockmon) {
		if !hash32_less(w.blockmon[i - 1].creature_id, w.blockmon[i].creature_id) {
			return .Unsorted_Blockmon
		}
	}
	for i in 1 ..< len(w.permits) {
		if !hash32_less(w.permits[i - 1].permit_id, w.permits[i].permit_id) {
			return .Unsorted_Permits
		}
	}
	for &p in w.permits {
		if p.encounter_class != ENCOUNTER_COMMON ||
		   (p.status != PERMIT_RESERVED && p.status != PERMIT_CONSUMED) {
			return .Bad_Enum
		}
	}
	s := w.supply
	if s.minted > s.envelope {
		return .Supply_Minted_Exceeds_Envelope // scheduled envelope ≥ Σ minted
	}
	if s.consumed > s.minted {
		return .Supply_Consumed_Exceeds_Minted
	}
	if s.created > s.consumed {
		return .Supply_Created_Exceeds_Consumed // creations ≤ consumed
	}
	if u64(len(w.blockmon)) != s.created {
		return .Extant_Mismatch // extant = created − exited; no exits in T1
	}
	return .Ok
}

// ---- canonical encodings (canonical-encoding.md §6) -----------------------------

encode_world :: proc(w: ^World) -> [dynamic]byte {
	buf: [dynamic]byte
	canonical.enc_seq_count(&buf, len(w.subjects))
	for &s in w.subjects {
		canonical.enc_hash32(&buf, s[:])
	}
	canonical.enc_seq_count(&buf, len(w.blockmon))
	for &b in w.blockmon {
		canonical.enc_hash32(&buf, b.creature_id[:])
		canonical.enc_hash32(&buf, b.owner[:])
		canonical.enc_hash32(&buf, b.origin_permit[:])
	}
	canonical.enc_seq_count(&buf, len(w.permits))
	for &p in w.permits {
		canonical.enc_hash32(&buf, p.permit_id[:])
		canonical.enc_hash32(&buf, p.subject[:])
		canonical.enc_enum(&buf, p.encounter_class)
		canonical.enc_u64(&buf, p.expiry_position)
		canonical.enc_enum(&buf, p.status)
	}
	canonical.enc_u64(&buf, w.supply.epoch)
	canonical.enc_u64(&buf, w.supply.envelope)
	canonical.enc_u64(&buf, w.supply.minted)
	canonical.enc_u64(&buf, w.supply.consumed)
	canonical.enc_u64(&buf, w.supply.created)
	return buf
}

// Flat commitment over the canonical state bytes. Provisional stand-in for the
// authenticated state tree, which remains OPEN in the protocol docket
// (canonical-encoding.md §6): proves deterministic root update, not inclusion.
world_root :: proc(w: ^World) -> [32]byte {
	bytes := encode_world(w)
	defer delete(bytes)
	return canonical.protocol_hash(canonical.DOMAIN_WORLD, bytes[:])
}

encode_manifest :: proc(m: ^Manifest) -> [dynamic]byte {
	buf: [dynamic]byte
	canonical.enc_u64(&buf, m.round_period)
	canonical.enc_u64(&buf, m.entropy_safety_margin)
	canonical.enc_u32(&buf, m.catch_rate_bp)
	return buf
}

manifest_hash :: proc(m: ^Manifest) -> [32]byte {
	bytes := encode_manifest(m)
	defer delete(bytes)
	return canonical.protocol_hash(canonical.DOMAIN_MANIFEST, bytes[:])
}

encode_command :: proc(c: ^Command) -> [dynamic]byte {
	buf: [dynamic]byte
	canonical.enc_hash32(&buf, c.subject[:])
	canonical.enc_hash32(&buf, c.permit_id[:])
	return buf
}

command_hash :: proc(c: ^Command) -> [32]byte {
	bytes := encode_command(c)
	defer delete(bytes)
	return canonical.protocol_hash(canonical.DOMAIN_CAPTURE_CMD, bytes[:])
}

encode_effects :: proc(fx: ^Effects) -> [dynamic]byte {
	buf: [dynamic]byte
	canonical.enc_enum(&buf, fx.outcome)
	canonical.enc_optional_flag(&buf, fx.outcome == OUTCOME_REJECTED)
	if fx.outcome == OUTCOME_REJECTED {
		canonical.enc_enum(&buf, fx.reject_reason)
	}
	canonical.enc_optional_flag(&buf, fx.outcome != OUTCOME_REJECTED)
	if fx.outcome != OUTCOME_REJECTED {
		canonical.enc_u64(&buf, fx.roll)
	}
	canonical.enc_optional_flag(&buf, fx.outcome == OUTCOME_CREATED)
	if fx.outcome == OUTCOME_CREATED {
		canonical.enc_hash32(&buf, fx.creature[:])
	}
	return buf
}

encode_transcript :: proc(t: ^Transcript) -> [dynamic]byte {
	buf: [dynamic]byte
	canonical.enc_hash32(&buf, t.command_hash[:])
	canonical.enc_hash32(&buf, t.prev_root[:])
	canonical.enc_hash32(&buf, t.next_root[:])
	fx_bytes := encode_effects(&t.effects)
	defer delete(fx_bytes)
	append(&buf, ..fx_bytes[:])
	return buf
}

transcript_hash :: proc(t: ^Transcript) -> [32]byte {
	bytes := encode_transcript(t)
	defer delete(bytes)
	return canonical.protocol_hash(canonical.DOMAIN_TRANSITION, bytes[:])
}

// ---- entropy assignment and capture roll -----------------------------------------

// Pure function of the sequencing position (protocol.md §5): calculates the
// first round whose reveal position may follow the command, plus a fixed
// safety margin. Round r reveals at position r * round_period, ensuring the
// reveal is strictly after the command for every position and margin.
assigned_round :: proc(position: u64, m: ^Manifest) -> u64 {
	assert(m.round_period > 0)
	return position / m.round_period + 1 + m.entropy_safety_margin
}

reveal_position :: proc(round: u64, m: ^Manifest) -> u64 {
	return round * m.round_period
}

// Domain-separated seed from (assigned round value, commitment data, manifest)
// per protocol.md §5.
capture_seed :: proc(entropy_value: [32]byte, permit_id: [32]byte, mh: [32]byte) -> [32]byte {
	entropy_value, permit_id, mh := entropy_value, permit_id, mh
	buf: [dynamic]byte
	defer delete(buf)
	canonical.enc_hash32(&buf, entropy_value[:])
	canonical.enc_hash32(&buf, permit_id[:])
	canonical.enc_hash32(&buf, mh[:])
	return canonical.protocol_hash(canonical.DOMAIN_CAPTURE_ROLL, buf[:])
}

roll_from_seed :: proc(seed: [32]byte) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v = v << 8 | u64(seed[i])
	}
	return v % ROLL_MODULUS
}

creature_id_from_permit :: proc(permit_id: [32]byte) -> [32]byte {
	permit_id := permit_id
	return canonical.protocol_hash(canonical.DOMAIN_CREATURE_ID, permit_id[:])
}

// ---- transition ---------------------------------------------------------------------

clone_world :: proc(w: ^World) -> World {
	out: World
	append(&out.subjects, ..w.subjects[:])
	append(&out.blockmon, ..w.blockmon[:])
	append(&out.permits, ..w.permits[:])
	out.supply = w.supply
	return out
}

destroy_world :: proc(w: ^World) {
	delete(w.subjects)
	delete(w.blockmon)
	delete(w.permits)
}

@(private)
reject :: proc(w: ^World, reason: u8) -> (World, Effects) {
	return clone_world(w), Effects{outcome = OUTCOME_REJECTED, reject_reason = reason}
}

// The Transition 1 kernel function. Totality: every well-typed command yields
// a defined outcome; rejection leaves the state byte-identical (the returned
// clone encodes equal to the input). Consume-on-attempt: preconditions met
// and roll executed means the permit and one capture-class capability are
// spent, regardless of success (protocol.md §6 coupling rule).
transition :: proc(w: ^World, cmd: Command, ctx: Context, m: ^Manifest) -> (next: World, fx: Effects) {
	cmd := cmd
	if validate_world(w) != .Ok {
		return reject(w, REJECT_INVALID_STATE)
	}
	if m.round_period == 0 {
		// Invalid manifest is boundary input like invalid state
		// (canonical-encoding.md §6), never an assert.
		return reject(w, REJECT_INVALID_STATE)
	}
	if ctx.epoch != w.supply.epoch {
		return reject(w, REJECT_WRONG_EPOCH)
	}
	if ctx.entropy_round != assigned_round(ctx.position, m) {
		return reject(w, REJECT_ENTROPY_MISMATCH) // choice-before-entropy, architecture.md §9
	}

	subject_found := false
	for &s in w.subjects {
		if s == cmd.subject {
			subject_found = true
			break
		}
	}
	if !subject_found {
		return reject(w, REJECT_UNKNOWN_SUBJECT)
	}

	permit_index := -1
	for &p, i in w.permits {
		if p.permit_id == cmd.permit_id {
			permit_index = i
			break
		}
	}
	if permit_index < 0 {
		return reject(w, REJECT_UNKNOWN_PERMIT)
	}
	permit := w.permits[permit_index]
	if permit.status != PERMIT_RESERVED {
		return reject(w, REJECT_PERMIT_NOT_RESERVED) // single reservation; no reuse
	}
	if permit.subject != cmd.subject {
		return reject(w, REJECT_WRONG_SUBJECT)
	}
	if ctx.position >= permit.expiry_position {
		return reject(w, REJECT_PERMIT_EXPIRED)
	}
	if w.supply.consumed >= w.supply.minted {
		return reject(w, REJECT_NO_CAPABILITY)
	}

	// Preconditions hold: the entropy-bound attempt executes. From here the
	// permit and one capability are consumed unconditionally.
	next = clone_world(w)
	next.permits[permit_index].status = PERMIT_CONSUMED
	next.supply.consumed += 1

	mh := manifest_hash(m)
	seed := capture_seed(ctx.entropy_value, cmd.permit_id, mh)
	roll := roll_from_seed(seed)

	if roll < u64(m.catch_rate_bp) {
		creature := creature_id_from_permit(cmd.permit_id)
		rec := Blockmon_Record{creature, cmd.subject, cmd.permit_id}
		at := len(next.blockmon)
		for &b, i in next.blockmon {
			if hash32_less(creature, b.creature_id) {
				at = i
				break
			}
		}
		inject_at(&next.blockmon, at, rec)
		next.supply.created += 1
		fx = Effects{outcome = OUTCOME_CREATED, roll = roll, creature = creature}
	} else {
		fx = Effects{outcome = OUTCOME_ROLL_FAILED, roll = roll} // waste, never mint
	}
	return next, fx
}

make_transcript :: proc(prev: ^World, next: ^World, cmd: Command, fx: Effects) -> Transcript {
	cmd := cmd
	return Transcript{command_hash(&cmd), world_root(prev), world_root(next), fx}
}
