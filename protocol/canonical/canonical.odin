// Canonical encoding and protocol hashing, v0. Normative authority:
// docs/architecture/canonical-encoding.md; this file implements that
// document, and on disagreement the document wins.
package canonical

import "core:crypto/sha2"
import "core:unicode/utf8"

// ---- domains (canonical-encoding.md §3) -------------------------------------

DOMAIN_OP :: "blockmon/op/v0"
DOMAIN_CHECKPOINT :: "blockmon/checkpoint/v0"
DOMAIN_STATE :: "blockmon/state/v0"

// Transition 1 kernel objects (canonical-encoding.md §6)
DOMAIN_WORLD :: "blockmon/world/v0"
DOMAIN_MANIFEST :: "blockmon/manifest/v0"
DOMAIN_CAPTURE_CMD :: "blockmon/capture-cmd/v0"
DOMAIN_TRANSITION :: "blockmon/transition/v0"
DOMAIN_CAPTURE_ROLL :: "blockmon/capture-roll/v0"
DOMAIN_CREATURE_ID :: "blockmon/creature-id/v0"

// ---- enums (canonical-encoding.md §4) ---------------------------------------

AUTHOR_A: u8 : 1
AUTHOR_B: u8 : 2

RESULT_A_WINS: u8 : 1
RESULT_B_WINS: u8 : 2
RESULT_DEFAULT: u8 : 3

// ---- encoding ----------------------------------------------------------------

enc_u8 :: proc(buf: ^[dynamic]byte, v: u8) {
	append(buf, v)
}

enc_u16 :: proc(buf: ^[dynamic]byte, v: u16) {
	append(buf, byte(v >> 8), byte(v))
}

enc_u32 :: proc(buf: ^[dynamic]byte, v: u32) {
	append(buf, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
}

enc_u64 :: proc(buf: ^[dynamic]byte, v: u64) {
	for i in 0 ..< 8 {
		append(buf, byte(v >> uint(56 - i * 8)))
	}
}

enc_bool :: proc(buf: ^[dynamic]byte, v: bool) {
	append(buf, byte(1) if v else byte(0))
}

enc_bytes :: proc(buf: ^[dynamic]byte, v: []byte) {
	assert(len(v) <= int(max(u32)))
	enc_u32(buf, u32(len(v)))
	append(buf, ..v)
}

enc_string :: proc(buf: ^[dynamic]byte, v: string) {
	assert(utf8.valid_string(v), "canonical strings must be valid UTF-8")
	enc_bytes(buf, transmute([]byte)v)
}

enc_hash32 :: proc(buf: ^[dynamic]byte, v: []byte) {
	assert(len(v) == 32)
	append(buf, ..v)
}

enc_enum :: proc(buf: ^[dynamic]byte, v: u8) {
	assert(v != 0, "enum discriminant 0 is invalid on the wire")
	append(buf, v)
}

enc_optional_flag :: proc(buf: ^[dynamic]byte, present: bool) {
	append(buf, byte(1) if present else byte(0))
}

enc_seq_count :: proc(buf: ^[dynamic]byte, n: int) {
	assert(n >= 0 && n <= int(max(u32)))
	enc_u32(buf, u32(n))
}

// ---- protocol hash (canonical-encoding.md §3) --------------------------------

protocol_hash :: proc(domain: string, payload: []byte) -> [32]byte {
	assert(len(domain) >= 1 && len(domain) <= 255, "domain must be 1-255 bytes")
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	l := [1]byte{byte(len(domain))}
	sha2.update(&ctx, l[:])
	sha2.update(&ctx, transmute([]byte)domain)
	sha2.update(&ctx, payload)
	out: [32]byte
	sha2.final(&ctx, out[:])
	return out
}

// ---- transcript objects (canonical-encoding.md §4) ----------------------------

Op :: struct {
	battle_id: [32]byte,
	seq:       u64,
	prev_hash: [32]byte,
	author:    u8, // AUTHOR_A | AUTHOR_B
	move:      string,
}

encode_op :: proc(op: Op) -> [dynamic]byte {
	op := op
	buf: [dynamic]byte
	enc_hash32(&buf, op.battle_id[:])
	enc_u64(&buf, op.seq)
	enc_hash32(&buf, op.prev_hash[:])
	enc_enum(&buf, op.author)
	enc_string(&buf, op.move)
	return buf
}

op_hash :: proc(op: Op) -> [32]byte {
	bytes := encode_op(op)
	defer delete(bytes)
	return protocol_hash(DOMAIN_OP, bytes[:])
}

Checkpoint :: struct {
	battle_id:       [32]byte,
	seq:             u64,
	transcript_head: [32]byte,
	result:          u8, // RESULT_*
}

encode_checkpoint :: proc(ck: Checkpoint) -> [dynamic]byte {
	ck := ck
	buf: [dynamic]byte
	enc_hash32(&buf, ck.battle_id[:])
	enc_u64(&buf, ck.seq)
	enc_hash32(&buf, ck.transcript_head[:])
	enc_enum(&buf, ck.result)
	return buf
}

checkpoint_hash :: proc(ck: Checkpoint) -> [32]byte {
	bytes := encode_checkpoint(ck)
	defer delete(bytes)
	return protocol_hash(DOMAIN_CHECKPOINT, bytes[:])
}

state_commitment :: proc(transcript_head: [32]byte, result: u8) -> [32]byte {
	transcript_head := transcript_head
	buf: [dynamic]byte
	defer delete(buf)
	enc_hash32(&buf, transcript_head[:])
	enc_enum(&buf, result)
	return protocol_hash(DOMAIN_STATE, buf[:])
}

// ---- strict decoding (rejection semantics; canonical-encoding.md §2) ----------
// Only what the rejection vectors exercise. Every reader MUST be this strict.

Decode_Error :: enum {
	None,
	Bad_Bool,
	Bad_Enum,
	Bad_Optional_Flag,
	Invalid_Utf8,
	Truncated,
	Trailing_Bytes,
}

Reader :: struct {
	data: []byte,
	off:  int,
}

read_exact :: proc(r: ^Reader, n: int) -> ([]byte, Decode_Error) {
	if r.off + n > len(r.data) {
		return nil, .Truncated
	}
	out := r.data[r.off:r.off + n]
	r.off += n
	return out, .None
}

dec_bool :: proc(r: ^Reader) -> (bool, Decode_Error) {
	b, err := read_exact(r, 1)
	if err != .None {
		return false, err
	}
	switch b[0] {
	case 0:
		return false, .None
	case 1:
		return true, .None
	}
	return false, .Bad_Bool
}

dec_u64 :: proc(r: ^Reader) -> (u64, Decode_Error) {
	b, err := read_exact(r, 8)
	if err != .None {
		return 0, err
	}
	v: u64
	for x in b {
		v = v << 8 | u64(x)
	}
	return v, .None
}

dec_string :: proc(r: ^Reader) -> (string, Decode_Error) {
	lb, err := read_exact(r, 4)
	if err != .None {
		return "", err
	}
	n := int(u32(lb[0]) << 24 | u32(lb[1]) << 16 | u32(lb[2]) << 8 | u32(lb[3]))
	b, err2 := read_exact(r, n)
	if err2 != .None {
		return "", err2
	}
	s := string(b)
	if !utf8.valid_string(s) {
		return "", .Invalid_Utf8
	}
	return s, .None
}

dec_enum :: proc(r: ^Reader, valid: []u8) -> (u8, Decode_Error) {
	b, err := read_exact(r, 1)
	if err != .None {
		return 0, err
	}
	for v in valid {
		if b[0] == v {
			return v, .None
		}
	}
	return 0, .Bad_Enum
}

dec_optional_flag :: proc(r: ^Reader) -> (bool, Decode_Error) {
	b, err := read_exact(r, 1)
	if err != .None {
		return false, err
	}
	switch b[0] {
	case 0:
		return false, .None
	case 1:
		return true, .None
	}
	return false, .Bad_Optional_Flag
}

// Top-level decodes must consume the input exactly.
finish :: proc(r: ^Reader) -> Decode_Error {
	return .None if r.off == len(r.data) else .Trailing_Bytes
}
