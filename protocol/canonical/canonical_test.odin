// Exercises the MUST-reject rules from §2 against this decoder. The archived
// rejection vectors are read only by check.py and the Rust cleanroom;
// conformance/gen is the sole driver of these procedures and is deliberately
// excluded from gates. Without this file, the reference reader lacks them
// entirely.
package canonical

import "core:testing"

@(test)
dec_bool_rejects_every_non_canonical_byte :: proc(t: ^testing.T) {
	for b in ([]byte{0, 1}) {
		buf := [1]byte{b}
		r := Reader{data = buf[:]}
		v, err := dec_bool(&r)
		testing.expect_value(t, err, Decode_Error.None)
		testing.expect_value(t, v, b == 1)
		testing.expect_value(t, finish(&r), Decode_Error.None)
	}
	for b in ([]byte{2, 3, 0x7f, 0x80, 0xff}) {
		buf := [1]byte{b}
		r := Reader{data = buf[:]}
		_, err := dec_bool(&r)
		testing.expect_value(t, err, Decode_Error.Bad_Bool)
	}
	empty := Reader{}
	_, err := dec_bool(&empty)
	testing.expect_value(t, err, Decode_Error.Truncated)
}

// Discriminant 0 is invalid on the wire throughout (§§4, 6), so reject
// it rather than treating it as an unassigned value.
@(test)
dec_enum_rejects_zero_and_unassigned_discriminants :: proc(t: ^testing.T) {
	assigned := []u8{AUTHOR_A, AUTHOR_B}
	for b in assigned {
		buf := [1]byte{b}
		r := Reader{data = buf[:]}
		v, err := dec_enum(&r, assigned)
		testing.expect_value(t, err, Decode_Error.None)
		testing.expect_value(t, v, b)
		testing.expect_value(t, finish(&r), Decode_Error.None)
	}
	for b in ([]byte{0, 3, 4, 0xff}) {
		buf := [1]byte{b}
		r := Reader{data = buf[:]}
		_, err := dec_enum(&r, assigned)
		testing.expect_value(t, err, Decode_Error.Bad_Enum)
	}

	results := []u8{RESULT_A_WINS, RESULT_B_WINS, RESULT_DEFAULT}
	zero := [1]byte{0}
	rz := Reader{data = zero[:]}
	_, rerr := dec_enum(&rz, results)
	testing.expect_value(t, rerr, Decode_Error.Bad_Enum)

	empty := Reader{}
	_, err := dec_enum(&empty, assigned)
	testing.expect_value(t, err, Decode_Error.Truncated)
}

@(test)
dec_optional_flag_rejects_a_flag_above_one :: proc(t: ^testing.T) {
	for b in ([]byte{0, 1}) {
		buf := [1]byte{b}
		r := Reader{data = buf[:]}
		present, err := dec_optional_flag(&r)
		testing.expect_value(t, err, Decode_Error.None)
		testing.expect_value(t, present, b == 1)
	}
	for b in ([]byte{2, 0x80, 0xff}) {
		buf := [1]byte{b}
		r := Reader{data = buf[:]}
		_, err := dec_optional_flag(&r)
		testing.expect_value(t, err, Decode_Error.Bad_Optional_Flag)
	}
}

@(test)
dec_u64_reads_big_endian_and_refuses_a_short_field :: proc(t: ^testing.T) {
	full := [8]byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF}
	r := Reader{data = full[:]}
	v, err := dec_u64(&r)
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, v, u64(0x0123_4567_89AB_CDEF))
	testing.expect_value(t, finish(&r), Decode_Error.None)

	short := Reader{data = full[:7]}
	_, serr := dec_u64(&short)
	testing.expect_value(t, serr, Decode_Error.Truncated)
}

@(test)
dec_string_rejects_invalid_utf8_and_both_truncations :: proc(t: ^testing.T) {
	// "h" ‖ U+00A3, so a multi-byte sequence is inside the accepted case
	ok := [7]byte{0, 0, 0, 3, 'h', 0xC2, 0xA3}
	r := Reader{data = ok[:]}
	s, err := dec_string(&r)
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, s, "h£")
	testing.expect_value(t, finish(&r), Decode_Error.None)

	// A lone continuation byte is invalid UTF-8; §2 forbids accepting it.
	bad := [5]byte{0, 0, 0, 1, 0x80}
	rb := Reader{data = bad[:]}
	_, berr := dec_string(&rb)
	testing.expect_value(t, berr, Decode_Error.Invalid_Utf8)

	rp := Reader{data = ok[:3]}
	_, perr := dec_string(&rp)
	testing.expect_value(t, perr, Decode_Error.Truncated)

	rbody := Reader{data = ok[:5]}
	_, boerr := dec_string(&rbody)
	testing.expect_value(t, boerr, Decode_Error.Truncated)

	// A length exceeding the remaining input, stated at the u32 maximum.
	huge := [4]byte{0xFF, 0xFF, 0xFF, 0xFF}
	rh := Reader{data = huge[:]}
	_, herr := dec_string(&rh)
	testing.expect_value(t, herr, Decode_Error.Truncated)
}

// §2: top-level decode must consume all input.
// Accepting a suffix lets one value take two encodings.
@(test)
finish_refuses_trailing_bytes :: proc(t: ^testing.T) {
	op := Op {
		battle_id = [32]byte{0 ..= 31 = 0x11},
		seq       = 7,
		prev_hash = [32]byte{0 ..= 31 = 0x22},
		author    = AUTHOR_B,
		move      = "move:ember",
	}
	bytes := encode_op(op)
	defer delete(bytes)

	exact := Reader{data = bytes[:]}
	testing.expect_value(t, read_op_fields(&exact), Decode_Error.None)
	testing.expect_value(t, finish(&exact), Decode_Error.None)

	trailing: [dynamic]byte
	defer delete(trailing)
	append(&trailing, ..bytes[:])
	append(&trailing, 0x00) // a single zero byte is the cheapest suffix
	loose := Reader{data = trailing[:]}
	testing.expect_value(t, read_op_fields(&loose), Decode_Error.None)
	testing.expect_value(t, finish(&loose), Decode_Error.Trailing_Bytes)
}

// Read §4's Op field sequence strictly, so the test above measures exact
// consumption, not where a decoder thinks the value ends.
read_op_fields :: proc(r: ^Reader) -> Decode_Error {
	if _, err := read_exact(r, 32); err != .None {
		return err
	}
	if _, err := dec_u64(r); err != .None {
		return err
	}
	if _, err := read_exact(r, 32); err != .None {
		return err
	}
	if _, err := dec_enum(r, []u8{AUTHOR_A, AUTHOR_B}); err != .None {
		return err
	}
	_, err := dec_string(r)
	return err
}

// §2: length prefixes keep concatenation unambiguous. Slice B's
// hand-rolled encoding collided on this pair.
@(test)
length_prefixes_separate_the_ambiguity_pair :: proc(t: ^testing.T) {
	first: [dynamic]byte
	defer delete(first)
	enc_string(&first, "A")
	enc_string(&first, "BC")

	second: [dynamic]byte
	defer delete(second)
	enc_string(&second, "AB")
	enc_string(&second, "C")

	testing.expect(t, len(first) == len(second), "the pair encodes to one length")
	testing.expect(t, !bytes_eq(first[:], second[:]), "the pair must not share an encoding")
}

// §2: an absent optional and an empty sequence are distinct. §3's domain
// length prefix keeps the domain/payload boundary unambiguous.
@(test)
absence_empty_and_the_domain_boundary_stay_distinct :: proc(t: ^testing.T) {
	absent: [dynamic]byte
	defer delete(absent)
	enc_optional_flag(&absent, false)

	empty_seq: [dynamic]byte
	defer delete(empty_seq)
	enc_seq_count(&empty_seq, 0)

	testing.expect(t, len(absent) != len(empty_seq), "absent and empty-seq differ in width")

	shifted := protocol_hash("blockmon/aa/v1", transmute([]byte)string("0b"))
	unshifted := protocol_hash("blockmon/aa/v10", transmute([]byte)string("b"))
	testing.expect(t, shifted != unshifted, "the domain boundary shift must change the hash")

	same_payload_a := protocol_hash(DOMAIN_OP, transmute([]byte)string("x"))
	same_payload_b := protocol_hash(DOMAIN_CHECKPOINT, transmute([]byte)string("x"))
	testing.expect(t, same_payload_a != same_payload_b, "one payload under two domains must differ")
}
