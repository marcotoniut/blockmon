// G0a golden-vector generator. Emits conformance/vectors/g0a-vectors.json.
// Refer to docs/architecture/canonical-encoding.md for the authority. This
// program is one implementation of the spec. conformance/check.py derives
// all values from the written spec without importing this code.
package g0a_gen

import canonical "../../protocol/canonical"
import kernel "../../protocol/kernel"

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

sha256_bytes :: proc(data: []byte) -> [32]byte {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	out: [32]byte
	sha2.final(&ctx, out[:])
	return out
}

hx :: proc(b: []byte) -> string {
	s, _ := hex.encode(b)
	return fmt.tprintf("0x%s", string(s))
}

out: strings.Builder
first_vector := true

emit :: proc(format: string, args: ..any) {
	fmt.sbprintf(&out, format, ..args)
}

vec_open :: proc(name, kind, source: string) {
	if !first_vector {
		emit(",\n")
	}
	first_vector = false
	emit("    {{\"name\": \"%s\", \"kind\": \"%s\", \"source\": \"%s\"", name, kind, source)
}

vec_close :: proc() {
	emit("}}")
}

encode_vec :: proc(name, source, type: string, value_json: string, canon: []byte, domain := "", hash: []byte = nil) {
	vec_open(name, "encode", source)
	emit(", \"type\": \"%s\", \"value\": %s, \"canonical\": \"%s\"", type, value_json, hx(canon))
	if domain != "" {
		emit(", \"domain\": \"%s\", \"hash\": \"%s\"", domain, hx(hash))
	}
	vec_close()
}

hash_vec :: proc(name, source, domain: string, payload: []byte) {
	h := canonical.protocol_hash(domain, payload)
	vec_open(name, "hash", source)
	emit(", \"domain\": \"%s\", \"payload\": \"%s\", \"hash\": \"%s\"", domain, hx(payload), hx(h[:]))
	vec_close()
}

reject_vec :: proc(name, decode, bytes_hex, error: string) {
	vec_open(name, "reject", "g0a")
	emit(", \"decode\": \"%s\", \"bytes\": \"%s\", \"error\": \"%s\"", decode, bytes_hex, error)
	vec_close()
}

// ---- Transition 1 vectors -----------------------------------------------------

t1_fill :: proc(b: byte) -> (out: [32]byte) {
	for i in 0 ..< 32 {
		out[i] = b
	}
	return
}

t1_world :: proc() -> kernel.World {
	w: kernel.World
	append(&w.subjects, t1_fill(0xAA), t1_fill(0xCC))
	append(&w.permits, kernel.Permit_Record{t1_fill(0xBB), t1_fill(0xAA), kernel.ENCOUNTER_COMMON, 1000, kernel.PERMIT_RESERVED})
	w.supply = kernel.Supply{epoch = 7, envelope = 100, minted = 10, consumed = 0, created = 0}
	return w
}

emit_world_json :: proc(w: ^kernel.World) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	fmt.sbprintf(&b, "{{\"subjects\": [")
	for &s, i in w.subjects {
		fmt.sbprintf(&b, "%s\"%s\"", i > 0 ? ", " : "", hx(s[:]))
	}
	fmt.sbprintf(&b, "], \"blockmon\": [")
	for &r, i in w.blockmon {
		fmt.sbprintf(
			&b, "%s{{\"creature_id\": \"%s\", \"owner\": \"%s\", \"origin_permit\": \"%s\"}}",
			i > 0 ? ", " : "", hx(r.creature_id[:]), hx(r.owner[:]), hx(r.origin_permit[:]),
		)
	}
	fmt.sbprintf(&b, "], \"permits\": [")
	for &p, i in w.permits {
		fmt.sbprintf(
			&b, "%s{{\"permit_id\": \"%s\", \"subject\": \"%s\", \"encounter_class\": %d, \"expiry_position\": \"%d\", \"status\": %d}}",
			i > 0 ? ", " : "", hx(p.permit_id[:]), hx(p.subject[:]), p.encounter_class, p.expiry_position, p.status,
		)
	}
	fmt.sbprintf(
		&b, "], \"supply\": {{\"epoch\": \"%d\", \"envelope\": \"%d\", \"minted\": \"%d\", \"consumed\": \"%d\", \"created\": \"%d\"}}}}",
		w.supply.epoch, w.supply.envelope, w.supply.minted, w.supply.consumed, w.supply.created,
	)
	return strings.to_string(b)
}

emit_effects_json :: proc(fx: ^kernel.Effects) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	fmt.sbprintf(&b, "{{\"outcome\": %d, \"reject_reason\": ", fx.outcome)
	if fx.outcome == kernel.OUTCOME_REJECTED {
		fmt.sbprintf(&b, "%d", fx.reject_reason)
	} else {
		fmt.sbprintf(&b, "null")
	}
	fmt.sbprintf(&b, ", \"roll\": ")
	if fx.outcome != kernel.OUTCOME_REJECTED {
		fmt.sbprintf(&b, "\"%d\"", fx.roll)
	} else {
		fmt.sbprintf(&b, "null")
	}
	fmt.sbprintf(&b, ", \"creature\": ")
	if fx.outcome == kernel.OUTCOME_CREATED {
		fmt.sbprintf(&b, "\"%s\"", hx(fx.creature[:]))
	} else {
		fmt.sbprintf(&b, "null")
	}
	fmt.sbprintf(&b, "}}")
	return strings.to_string(b)
}

// protocol.md §10, the identities Transition 1 can express: envelope and
// minted conserved, consume-on-attempt, creations ≤ consumed, extant ==
// created, rejection leaves the canonical bytes untouched. Asserted before
// any vector is emitted; cross-platform byte agreement alone cannot pass G0.
assert_t1_conservation :: proc(name: string, w: ^kernel.World, next: ^kernel.World, cmd: kernel.Command, fx: kernel.Effects, m: ^kernel.Manifest) {
	ok := next.supply.envelope == w.supply.envelope && next.supply.minted == w.supply.minted
	if fx.outcome == kernel.OUTCOME_REJECTED {
		a := kernel.encode_world(w)
		b := kernel.encode_world(next)
		ok &&= slice.equal(a[:], b[:])
	} else {
		ok &&= next.supply.consumed == w.supply.consumed + 1
		delta: u64 = 1 if fx.outcome == kernel.OUTCOME_CREATED else 0
		ok &&= next.supply.created == w.supply.created + delta
		ok &&= next.supply.created <= next.supply.consumed
		ok &&= next.supply.consumed <= next.supply.minted && next.supply.minted <= next.supply.envelope
		ok &&= u64(len(next.blockmon)) == next.supply.created
		consumed := false
		for &p in next.permits {
			if p.permit_id == cmd.permit_id {
				consumed = p.status == kernel.PERMIT_CONSUMED
				break
			}
		}
		ok &&= consumed
		ok &&= (fx.outcome == kernel.OUTCOME_CREATED) == (fx.roll < u64(m.catch_rate_bp))
	}
	if !ok {
		fmt.eprintln("conservation identity violated before emit:", name)
		os.exit(1)
	}
}

// expect: -1 no expectation, 0 the attempt must execute, 1-9 the rejection reason
transition_vec :: proc(name: string, w: ^kernel.World, cmd: kernel.Command, ctx: kernel.Context, m: ^kernel.Manifest, expect := -1) {
	cmd := cmd
	ctx := ctx
	next, fx := kernel.transition(w, cmd, ctx, m)

	if expect == 0 && fx.outcome == kernel.OUTCOME_REJECTED {
		fmt.eprintln("gen: expected attempt, got rejection:", name, fx.reject_reason)
		os.exit(1)
	}
	if expect > 0 && (fx.outcome != kernel.OUTCOME_REJECTED || int(fx.reject_reason) != expect) {
		fmt.eprintln("gen: expected rejection reason", expect, "got", fx.outcome, fx.reject_reason, "for", name)
		os.exit(1)
	}
	assert_t1_conservation(name, w, &next, cmd, fx, m)

	m_bytes := kernel.encode_manifest(m)
	mh := kernel.manifest_hash(m)
	in_bytes := kernel.encode_world(w)
	in_root := kernel.world_root(w)
	cmd_bytes := kernel.encode_command(&cmd)
	cmd_h := kernel.command_hash(&cmd)
	out_bytes := kernel.encode_world(&next)
	out_root := kernel.world_root(&next)
	fx_bytes := kernel.encode_effects(&fx)
	tr := kernel.make_transcript(w, &next, cmd, fx)
	tr_h := kernel.transcript_hash(&tr)

	vec_open(name, "transition", "t1")
	emit(
		", \"manifest\": {{\"round_period\": \"%d\", \"entropy_safety_margin\": \"%d\", \"catch_rate_bp\": \"%d\"}}",
		m.round_period, m.entropy_safety_margin, m.catch_rate_bp,
	)
	emit(", \"manifest_canonical\": \"%s\", \"manifest_hash\": \"%s\"", hx(m_bytes[:]), hx(mh[:]))
	emit(", \"input_state\": %s", emit_world_json(w))
	emit(", \"input_canonical\": \"%s\", \"input_root\": \"%s\"", hx(in_bytes[:]), hx(in_root[:]))
	emit(
		", \"command\": {{\"subject\": \"%s\", \"permit_id\": \"%s\"}}, \"command_canonical\": \"%s\", \"command_hash\": \"%s\"",
		hx(cmd.subject[:]), hx(cmd.permit_id[:]), hx(cmd_bytes[:]), hx(cmd_h[:]),
	)
	emit(
		", \"context\": {{\"position\": \"%d\", \"epoch\": \"%d\", \"entropy_round\": \"%d\", \"entropy_value\": \"%s\"}}",
		ctx.position, ctx.epoch, ctx.entropy_round, hx(ctx.entropy_value[:]),
	)
	if fx.outcome != kernel.OUTCOME_REJECTED {
		seed := kernel.capture_seed(ctx.entropy_value, cmd.permit_id, mh)
		emit(", \"seed\": \"%s\"", hx(seed[:]))
	} else {
		emit(", \"seed\": null")
	}
	emit(", \"output_state\": %s", emit_world_json(&next))
	emit(", \"output_canonical\": \"%s\", \"output_root\": \"%s\"", hx(out_bytes[:]), hx(out_root[:]))
	emit(", \"effects\": %s, \"effects_canonical\": \"%s\"", emit_effects_json(&fx), hx(fx_bytes[:]))
	emit(", \"transcript_hash\": \"%s\"", hx(tr_h[:]))
	vec_close()
}

emit_transition_vectors :: proc() {
	m := kernel.Manifest{round_period = 32, entropy_safety_margin = 2, catch_rate_bp = 2500}
	cmd := kernel.Command{subject = t1_fill(0xAA), permit_id = t1_fill(0xBB)}
	// position 100 -> assigned round 6
	ctx := kernel.Context{position = 100, epoch = 7, entropy_round = 6, entropy_value = t1_fill(0x01)}

	w1 := t1_world()
	transition_vec("t1-capture-success", &w1, cmd, ctx, &m)

	w2 := t1_world()
	ctx_fail := ctx
	ctx_fail.entropy_value = t1_fill(0x00)
	transition_vec("t1-capture-roll-failed", &w2, cmd, ctx_fail, &m)

	w3 := t1_world()
	w3.permits[0].expiry_position = 100 // exclusive bound: expired at position 100
	transition_vec("t1-rejected-expired", &w3, cmd, ctx, &m)
}

dec_len_prefixed :: proc(r: ^canonical.Reader) -> canonical.Decode_Error {
	lb, err := canonical.read_exact(r, 4)
	if err != .None {
		return err
	}
	n := int(u32(lb[0]) << 24 | u32(lb[1]) << 16 | u32(lb[2]) << 8 | u32(lb[3]))
	_, err2 := canonical.read_exact(r, n)
	return err2
}

// self-check: the generator's own strict decoder must reject every reject vector
assert_rejected :: proc(decode: string, raw: []byte) {
	r := canonical.Reader{data = raw}
	err: canonical.Decode_Error
	switch decode {
	case "bool":
		_, err = canonical.dec_bool(&r)
	case "u8":
		_, err = canonical.read_exact(&r, 1)
	case "u16":
		_, err = canonical.read_exact(&r, 2)
	case "u32":
		_, err = canonical.read_exact(&r, 4)
	case "u64":
		_, err = canonical.dec_u64(&r)
	case "string":
		_, err = canonical.dec_string(&r)
	case "bytes":
		err = dec_len_prefixed(&r)
	case "hash32":
		_, err = canonical.read_exact(&r, 32)
	case "enum:author":
		_, err = canonical.dec_enum(&r, []u8{canonical.AUTHOR_A, canonical.AUTHOR_B})
	case "enum:result":
		_, err = canonical.dec_enum(&r, []u8{canonical.RESULT_A_WINS, canonical.RESULT_B_WINS, canonical.RESULT_DEFAULT})
	case "optional:u64":
		present: bool
		present, err = canonical.dec_optional_flag(&r)
		if err == .None && present {
			_, err = canonical.dec_u64(&r)
		}
	case "optional:bytes":
		present: bool
		present, err = canonical.dec_optional_flag(&r)
		if err == .None && present {
			err = dec_len_prefixed(&r)
		}
	case "seq:u64":
		lb: []byte
		lb, err = canonical.read_exact(&r, 4)
		if err == .None {
			n := int(u32(lb[0]) << 24 | u32(lb[1]) << 16 | u32(lb[2]) << 8 | u32(lb[3]))
			for _ in 0 ..< n {
				_, err = canonical.dec_u64(&r)
				if err != .None {
					break
				}
			}
		}
	case:
		fmt.eprintln("unknown reject decode kind:", decode)
		os.exit(1)
	}
	if err == .None {
		err = canonical.finish(&r)
	}
	if err == .None {
		fmt.eprintln("self-check failed: decoder accepted reject vector for", decode)
		os.exit(1)
	}
}

// ---- expansion tier -----------------------------------------------------------
// G0a's 10³-scale tier: the observable boundaries the seed corpus pins, at
// volume, from a fixed literal seed (splitmix64, as in conformance/fuzz; no
// OS randomness). Emitted by `g0a-gen expansion` into
// conformance/vectors/g0a-expansion.json; the seed corpus stays byte-identical.

EXPANSION_SEED: u64 : 0x60A0EC5EED

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

rand_bytes :: proc(r: ^Rng, n: int) -> []byte {
	b := make([]byte, n)
	for i in 0 ..< n {
		b[i] = byte(next_u64(r))
	}
	return b
}

// JSON-safe by construction: no quotes, backslashes or control characters
rand_ascii :: proc(r: ^Rng, n: int) -> string {
	alphabet := "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i in 0 ..< n {
		b[i] = alphabet[rand_below(r, u64(len(alphabet)))]
	}
	return string(b)
}

x_ints :: proc(r: ^Rng) {
	buf: [dynamic]byte
	Width :: struct {
		name:   string,
		bits:   uint,
		seeded: int,
	}
	widths := [?]Width{{"u8", 8, 20}, {"u16", 16, 40}, {"u32", 32, 60}, {"u64", 64, 80}}
	for w in widths {
		maxv := max(u64) >> (64 - w.bits)
		vals: [dynamic]u64
		defer delete(vals)
		// at and around every byte-width boundary, the sign bit, and the maximum
		append(&vals, 0, 1, 2)
		for k := uint(8); k < w.bits; k += 8 {
			b := u64(1) << k
			append(&vals, b - 1, b, b + 1)
		}
		hi := u64(1) << (w.bits - 1)
		append(&vals, hi - 1, hi, maxv - 1, maxv)
		for _ in 0 ..< w.seeded {
			append(&vals, next_u64(r) & maxv)
		}
		for v, i in vals {
			clear(&buf)
			switch w.bits {
			case 8:
				canonical.enc_u8(&buf, u8(v))
			case 16:
				canonical.enc_u16(&buf, u16(v))
			case 32:
				canonical.enc_u32(&buf, u32(v))
			case 64:
				canonical.enc_u64(&buf, v)
			}
			encode_vec(fmt.tprintf("x-%s-%03d", w.name, i), "g0a-x", w.name, fmt.tprintf("\"%d\"", v), buf[:])
		}
	}
}

x_bytes_strings :: proc(r: ^Rng) {
	buf: [dynamic]byte
	blens := [?]int{0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257, 511, 512, 1024}
	for n in blens {
		p := rand_bytes(r, n)
		clear(&buf)
		canonical.enc_bytes(&buf, p)
		encode_vec(fmt.tprintf("x-bytes-len-%04d", n), "g0a-x", "bytes", fmt.tprintf("\"%s\"", hx(p)), buf[:])
	}
	slens := [?]int{0, 1, 2, 3, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256, 257}
	for n in slens {
		s := rand_ascii(r, n)
		clear(&buf)
		canonical.enc_string(&buf, s)
		encode_vec(fmt.tprintf("x-string-len-%04d", n), "g0a-x", "string", fmt.tprintf("\"%s\"", s), buf[:])
	}
	// first/last code points of each UTF-8 encoded width, around the
	// surrogate gap, astral plane, and mixed-width strings
	edges := [?]string{
		"\u0080", "\u07ff", "\u0800", "\ud7ff", "\ue000", "\ufffd", "\uffff",
		"\U00010000", "\U0010ffff",
		"a\u0080z", "\u00e9\u26a1", "\u65e5\u672c\u8a9e\u30c6\u30ad\u30b9\u30c8", "\U0001f7e9\U0001f7e5\U0001f7e6", "a\u00e9\u26a1\U0001f7e9\U0001d11e",
	}
	for s, i in edges {
		clear(&buf)
		canonical.enc_string(&buf, s)
		encode_vec(fmt.tprintf("x-string-utf8-%02d", i), "g0a-x", "string", fmt.tprintf("\"%s\"", s), buf[:])
	}
	palette := [?]string{"a", "k", "z", "0", "7", "é", "ß", "µ", "€", "⚡", "日", "語", "🟩", "𝄞"}
	for i in 0 ..< 30 {
		b: strings.Builder
		strings.builder_init(&b)
		for _ in 0 ..< 1 + rand_below(r, 20) {
			strings.write_string(&b, palette[rand_below(r, u64(len(palette)))])
		}
		s := strings.to_string(b)
		clear(&buf)
		canonical.enc_string(&buf, s)
		encode_vec(fmt.tprintf("x-string-mixed-%02d", i), "g0a-x", "string", fmt.tprintf("\"%s\"", s), buf[:])
	}
	for i in 0 ..< 10 {
		h := rand_h32(r)
		clear(&buf)
		canonical.enc_hash32(&buf, h[:])
		encode_vec(fmt.tprintf("x-hash32-%02d", i), "g0a-x", "hash32", fmt.tprintf("\"%s\"", hx(h[:])), buf[:])
	}
}

x_optionals_seqs :: proc(r: ^Rng) {
	buf: [dynamic]byte

	ovals := [?]u64{0, 1, 255, 256, 65535, 65536, 4294967295, 4294967296, max(u64)}
	clear(&buf)
	canonical.enc_optional_flag(&buf, false)
	encode_vec("x-optional-u64-absent", "g0a-x", "optional:u64", "null", buf[:])
	for v, i in ovals {
		clear(&buf)
		canonical.enc_optional_flag(&buf, true)
		canonical.enc_u64(&buf, v)
		encode_vec(fmt.tprintf("x-optional-u64-%02d", i), "g0a-x", "optional:u64", fmt.tprintf("\"%d\"", v), buf[:])
	}

	obl := [?]int{0, 1, 4, 32}
	for n, i in obl {
		p := rand_bytes(r, n)
		clear(&buf)
		canonical.enc_optional_flag(&buf, true)
		canonical.enc_bytes(&buf, p)
		encode_vec(fmt.tprintf("x-optional-bytes-%02d", i), "g0a-x", "optional:bytes", fmt.tprintf("\"%s\"", hx(p)), buf[:])
	}
	clear(&buf)
	canonical.enc_optional_flag(&buf, false)
	encode_vec("x-optional-string-absent", "g0a-x", "optional:string", "null", buf[:])
	ostr := [?]string{"", "x", "héllo⚡"}
	for s, i in ostr {
		clear(&buf)
		canonical.enc_optional_flag(&buf, true)
		canonical.enc_string(&buf, s)
		encode_vec(fmt.tprintf("x-optional-string-%02d", i), "g0a-x", "optional:string", fmt.tprintf("\"%s\"", s), buf[:])
	}

	counts := [?]int{0, 1, 2, 3, 4, 5, 8, 16, 32, 64}
	for n in counts {
		clear(&buf)
		canonical.enc_seq_count(&buf, n)
		js: strings.Builder
		strings.builder_init(&js)
		strings.write_byte(&js, '[')
		for i in 0 ..< n {
			v := next_u64(r)
			canonical.enc_u64(&buf, v)
			fmt.sbprintf(&js, "%s\"%d\"", i > 0 ? ", " : "", v)
		}
		strings.write_byte(&js, ']')
		encode_vec(fmt.tprintf("x-seq-u64-len-%02d", n), "g0a-x", "seq:u64", strings.to_string(js), buf[:])
	}
	scounts := [?]int{0, 1, 2, 3, 5, 8}
	for n in scounts {
		clear(&buf)
		canonical.enc_seq_count(&buf, n)
		js: strings.Builder
		strings.builder_init(&js)
		strings.write_byte(&js, '[')
		for i in 0 ..< n {
			s := rand_ascii(r, int(rand_below(r, 9)))
			canonical.enc_string(&buf, s)
			fmt.sbprintf(&js, "%s\"%s\"", i > 0 ? ", " : "", s)
		}
		strings.write_byte(&js, ']')
		encode_vec(fmt.tprintf("x-seq-string-len-%02d", n), "g0a-x", "seq:string", strings.to_string(js), buf[:])
	}
	bcounts := [?]int{0, 1, 2, 4}
	for n in bcounts {
		clear(&buf)
		canonical.enc_seq_count(&buf, n)
		js: strings.Builder
		strings.builder_init(&js)
		strings.write_byte(&js, '[')
		for i in 0 ..< n {
			p := rand_bytes(r, int(rand_below(r, 6)))
			canonical.enc_bytes(&buf, p)
			fmt.sbprintf(&js, "%s\"%s\"", i > 0 ? ", " : "", hx(p))
		}
		strings.write_byte(&js, ']')
		encode_vec(fmt.tprintf("x-seq-bytes-len-%02d", n), "g0a-x", "seq:bytes", strings.to_string(js), buf[:])
	}

	// nesting: empty-inside-empty distinctions are where framing bugs hide
	nested := [?][][]u64{
		{},
		{{}},
		{{}, {}},
		{{7}},
		{{}, {1, 2}, {}},
		{{max(u64)}, {0, 1, 2}},
	}
	for shape, si in nested {
		clear(&buf)
		canonical.enc_seq_count(&buf, len(shape))
		js: strings.Builder
		strings.builder_init(&js)
		strings.write_byte(&js, '[')
		for inner, ii in shape {
			canonical.enc_seq_count(&buf, len(inner))
			fmt.sbprintf(&js, "%s[", ii > 0 ? ", " : "")
			for v, vi in inner {
				canonical.enc_u64(&buf, v)
				fmt.sbprintf(&js, "%s\"%d\"", vi > 0 ? ", " : "", v)
			}
			strings.write_byte(&js, ']')
		}
		strings.write_byte(&js, ']')
		encode_vec(fmt.tprintf("x-seq-seq-u64-%d", si), "g0a-x", "seq:seq:u64", strings.to_string(js), buf[:])
	}

	clear(&buf)
	canonical.enc_optional_flag(&buf, false)
	encode_vec("x-optional-seq-u64-absent", "g0a-x", "optional:seq:u64", "null", buf[:])
	oseqs := [?][]u64{{}, {1}, {0, max(u64), 7}}
	for vs, i in oseqs {
		clear(&buf)
		canonical.enc_optional_flag(&buf, true)
		canonical.enc_seq_count(&buf, len(vs))
		js: strings.Builder
		strings.builder_init(&js)
		strings.write_byte(&js, '[')
		for v, vi in vs {
			canonical.enc_u64(&buf, v)
			fmt.sbprintf(&js, "%s\"%d\"", vi > 0 ? ", " : "", v)
		}
		strings.write_byte(&js, ']')
		encode_vec(fmt.tprintf("x-optional-seq-u64-%d", i), "g0a-x", "optional:seq:u64", strings.to_string(js), buf[:])
	}

	clear(&buf)
	canonical.enc_seq_count(&buf, 0)
	encode_vec("x-seq-optional-u64-0", "g0a-x", "seq:optional:u64", "[]", buf[:])
	clear(&buf)
	canonical.enc_seq_count(&buf, 1)
	canonical.enc_optional_flag(&buf, false)
	encode_vec("x-seq-optional-u64-1", "g0a-x", "seq:optional:u64", "[null]", buf[:])
	clear(&buf)
	canonical.enc_seq_count(&buf, 1)
	canonical.enc_optional_flag(&buf, true)
	canonical.enc_u64(&buf, 7)
	encode_vec("x-seq-optional-u64-2", "g0a-x", "seq:optional:u64", "[\"7\"]", buf[:])
	clear(&buf)
	canonical.enc_seq_count(&buf, 3)
	canonical.enc_optional_flag(&buf, false)
	canonical.enc_optional_flag(&buf, true)
	canonical.enc_u64(&buf, 5)
	canonical.enc_optional_flag(&buf, false)
	encode_vec("x-seq-optional-u64-3", "g0a-x", "seq:optional:u64", "[null, \"5\", null]", buf[:])
}

x_records :: proc(r: ^Rng) {
	move_lens := [?]int{0, 1, 2, 31, 32, 33, 255, 256}
	for i in 0 ..< 40 {
		battle := rand_h32(r)
		prev := rand_h32(r)
		seqv := next_u64(r) >> uint(rand_below(r, 64)) // varied byte-width magnitudes
		move := rand_ascii(r, move_lens[i % len(move_lens)])
		op := canonical.Op{battle, seqv, prev, u8(1 + i % 2), move}
		ob := canonical.encode_op(op)
		oh := canonical.op_hash(op)
		val := fmt.tprintf(
			"{{\"battle_id\": \"%s\", \"seq\": \"%d\", \"prev_hash\": \"%s\", \"author\": %d, \"move\": \"%s\"}}",
			hx(battle[:]), seqv, hx(prev[:]), op.author, move,
		)
		encode_vec(fmt.tprintf("x-op-%02d", i), "g0a-x", "record:op", val, ob[:], canonical.DOMAIN_OP, oh[:])
	}
	for i in 0 ..< 20 {
		battle := rand_h32(r)
		head := rand_h32(r)
		seqv := 1 + next_u64(r) >> uint(rand_below(r, 64))
		ck := canonical.Checkpoint{battle, seqv, head, u8(1 + i % 3)}
		cb := canonical.encode_checkpoint(ck)
		ch := canonical.checkpoint_hash(ck)
		val := fmt.tprintf(
			"{{\"battle_id\": \"%s\", \"seq\": \"%d\", \"transcript_head\": \"%s\", \"result\": %d}}",
			hx(battle[:]), seqv, hx(head[:]), ck.result,
		)
		encode_vec(fmt.tprintf("x-checkpoint-%02d", i), "g0a-x", "record:checkpoint", val, cb[:], canonical.DOMAIN_CHECKPOINT, ch[:])
	}
	for i in 0 ..< 12 {
		head := rand_h32(r)
		result := u8(1 + i % 3)
		sc := canonical.state_commitment(head, result)
		buf: [dynamic]byte
		canonical.enc_hash32(&buf, head[:])
		canonical.enc_enum(&buf, result)
		val := fmt.tprintf("{{\"transcript_head\": \"%s\", \"result\": %d}}", hx(head[:]), result)
		encode_vec(fmt.tprintf("x-state-%02d", i), "g0a-x", "record:state", val, buf[:], canonical.DOMAIN_STATE, sc[:])
		delete(buf)
	}
	// seeded split-point pairs: same concatenation, distinct framing
	for i in 0 ..< 16 {
		s := rand_ascii(r, 2 + int(rand_below(r, 10)))
		cut := int(rand_below(r, u64(len(s) + 1)))
		a, b := s[:cut], s[cut:]
		buf: [dynamic]byte
		canonical.enc_string(&buf, a)
		canonical.enc_string(&buf, b)
		h := canonical.protocol_hash(canonical.DOMAIN_OP, buf[:])
		encode_vec(
			fmt.tprintf("x-string2-%02d", i), "g0a-x", "record:string2",
			fmt.tprintf("[\"%s\", \"%s\"]", a, b), buf[:], canonical.DOMAIN_OP, h[:],
		)
		delete(buf)
	}
}

x_transcripts :: proc(r: ^Rng) {
	for l in 1 ..= 16 {
		for variant in 0 ..< 2 {
			battle := rand_h32(r)
			prev: [32]byte
			js: strings.Builder
			strings.builder_init(&js)
			for s in 1 ..= l {
				author := u8(1 + rand_below(r, 2))
				move := rand_ascii(r, int(1 + rand_below(r, 12)))
				op := canonical.Op{battle, u64(s), prev, author, move}
				prev = canonical.op_hash(op)
				fmt.sbprintf(&js, "%s{{\"author\": %d, \"move\": \"%s\"}}", s > 1 ? ", " : "", author, move)
			}
			vec_open(fmt.tprintf("x-transcript-%02d-%d", l, variant), "transcript", "g0a-x")
			emit(", \"battle_id\": \"%s\", \"ops\": [%s], \"head\": \"%s\"", hx(battle[:]), strings.to_string(js), hx(prev[:]))
			vec_close()
		}
	}
}

x_hashes :: proc(r: ^Rng) {
	domains := [?]string{
		canonical.DOMAIN_OP, canonical.DOMAIN_CHECKPOINT, canonical.DOMAIN_STATE,
		canonical.DOMAIN_WORLD, canonical.DOMAIN_MANIFEST, canonical.DOMAIN_CAPTURE_CMD,
		canonical.DOMAIN_TRANSITION, canonical.DOMAIN_CAPTURE_ROLL, canonical.DOMAIN_CREATURE_ID,
	}
	lens := [?]int{0, 1, 2, 32, 33, 255, 256}
	for d, di in domains {
		for n, ni in lens {
			hash_vec(fmt.tprintf("x-hash-%d-%d", di, ni), "g0a-x", d, rand_bytes(r, n))
		}
	}
	// one payload under every assigned domain: distinct by construction
	shared := rand_bytes(r, 24)
	for d, di in domains {
		hash_vec(fmt.tprintf("x-hash-shared-%d", di), "g0a-x", d, shared)
	}
	// domain length boundaries (1-255 printable, /v<decimal> suffix)
	dlens := [?]int{4, 5, 8, 16, 64, 128, 254, 255}
	for l in dlens {
		b: strings.Builder
		strings.builder_init(&b)
		for _ in 0 ..< l - 3 {
			strings.write_byte(&b, 'a')
		}
		strings.write_string(&b, "/v0")
		hash_vec(fmt.tprintf("x-hash-domain-len-%03d", l), "g0a-x", strings.to_string(b), rand_bytes(r, 8))
	}
}

sorted_ids :: proc(r: ^Rng, n: int) -> [dynamic][32]byte {
	out: [dynamic][32]byte
	for _ in 0 ..< n {
		append(&out, rand_h32(r)) // 256-bit ids: duplicate probability negligible
	}
	slice.sort_by(out[:], kernel.hash32_less)
	return out
}

// A valid world per canonical-encoding.md §6, small enough to keep the
// artefact readable: 2-3 subjects, 1-3 permits, minted always leaves capacity.
x_world :: proc(r: ^Rng) -> kernel.World {
	w: kernel.World
	w.subjects = sorted_ids(r, 2 + int(rand_below(r, 2)))
	created := rand_below(r, 3)
	consumed := created + rand_below(r, 3)
	minted := consumed + 1 + rand_below(r, 4)
	w.supply = kernel.Supply{
		epoch    = rand_below(r, 100),
		envelope = minted + rand_below(r, 20),
		minted   = minted,
		consumed = consumed,
		created  = created,
	}
	mons := sorted_ids(r, int(created))
	defer delete(mons)
	for id in mons {
		append(&w.blockmon, kernel.Blockmon_Record{id, w.subjects[rand_below(r, u64(len(w.subjects)))], rand_h32(r)})
	}
	permits := sorted_ids(r, 1 + int(rand_below(r, 3)))
	defer delete(permits)
	for id, i in permits {
		status := kernel.PERMIT_RESERVED if i == 0 || rand_below(r, 4) > 0 else kernel.PERMIT_CONSUMED
		append(&w.permits, kernel.Permit_Record{
			id, w.subjects[rand_below(r, u64(len(w.subjects)))],
			kernel.ENCOUNTER_COMMON, 1 + rand_below(r, 1 << 20), status,
		})
	}
	return w
}

x_manifest :: proc(r: ^Rng) -> kernel.Manifest {
	rp: u64
	switch rand_below(r, 5) {
	case 0:
		rp = 1
	case 1:
		rp = 2
	case 2:
		rp = 32
	case 3:
		rp = 512
	case:
		rp = 1 + rand_below(r, 4096)
	}
	return kernel.Manifest{
		round_period          = rp,
		entropy_safety_margin = rand_below(r, 9),
		catch_rate_bp         = u32(rand_below(r, 10_001)),
	}
}

x_transitions :: proc(r: ^Rng) {
	labels := [?]string{
		"attempt", "expiry-edge", "always", "never", "above-modulus", "rare", "likely",
		"unknown-subject", "unknown-permit", "not-reserved", "wrong-subject",
		"expired", "no-capability", "entropy-mismatch", "wrong-epoch", "invalid-state",
		"invalid-consumed-gt-minted", "invalid-minted-gt-envelope",
		"invalid-encounter-class", "invalid-status",
		"invalid-unsorted-subjects", "invalid-unsorted-blockmon", "invalid-unsorted-permits",
		"invalid-manifest-zero-period", "invalid-extant-mismatch",
	}
	N :: 325
	for i in 0 ..< N {
		w := x_world(r)
		m := x_manifest(r)
		reserved: [dynamic]int
		for &p, idx in w.permits {
			if p.status == kernel.PERMIT_RESERVED {
				append(&reserved, idx)
			}
		}
		pi := reserved[rand_below(r, u64(len(reserved)))]
		delete(reserved)
		p := w.permits[pi]
		cmd := kernel.Command{subject = p.subject, permit_id = p.permit_id}
		ctx := kernel.Context{
			position      = rand_below(r, p.expiry_position),
			epoch         = w.supply.epoch,
			entropy_value = rand_h32(r),
		}
		if i % 5 == 0 {
			ctx.entropy_value = t1_fill(byte(i))
		}
		class := i % len(labels)
		expect := 0
		switch class {
		case 1:
			ctx.position = p.expiry_position - 1 // exclusive bound: last valid position
		case 2:
			m.catch_rate_bp = 10_000
		case 3:
			m.catch_rate_bp = 0
		case 4:
			m.catch_rate_bp = 12_345 // above the modulus: legal, always captures
		case 5:
			m.catch_rate_bp = 1
		case 6:
			m.catch_rate_bp = 9_999
		case 7:
			cmd.subject = rand_h32(r)
			expect = int(kernel.REJECT_UNKNOWN_SUBJECT)
		case 8:
			cmd.permit_id = rand_h32(r)
			expect = int(kernel.REJECT_UNKNOWN_PERMIT)
		case 9:
			w.permits[pi].status = kernel.PERMIT_CONSUMED
			expect = int(kernel.REJECT_PERMIT_NOT_RESERVED)
		case 10:
			cmd.subject = w.subjects[0] if w.subjects[0] != p.subject else w.subjects[1]
			expect = int(kernel.REJECT_WRONG_SUBJECT)
		case 11:
			bump := rand_below(r, 3)
			ctx.position = p.expiry_position + (100_000 + rand_below(r, 1 << 30) if bump == 2 else bump)
			expect = int(kernel.REJECT_PERMIT_EXPIRED)
		case 12:
			w.supply.consumed = w.supply.minted
			expect = int(kernel.REJECT_NO_CAPABILITY)
		case 14:
			ctx.epoch += 1 + rand_below(r, 5)
			expect = int(kernel.REJECT_WRONG_EPOCH)
		case 15:
			w.supply.created = w.supply.consumed + 1
			expect = int(kernel.REJECT_INVALID_STATE)
		case 16:
			w.supply.consumed = w.supply.minted + 1 + rand_below(r, 3)
			expect = int(kernel.REJECT_INVALID_STATE)
		case 17:
			w.supply.minted = w.supply.envelope + 1 + rand_below(r, 4)
			expect = int(kernel.REJECT_INVALID_STATE)
		case 18:
			// only COMMON = 1 is assigned; 0 is unrepresentable (enc_enum rejects it)
			w.permits[pi].encounter_class = u8(2 + rand_below(r, 254))
			expect = int(kernel.REJECT_INVALID_STATE)
		case 19:
			// only RESERVED = 1 and CONSUMED = 2 are assigned
			w.permits[pi].status = u8(3 + rand_below(r, 253))
			expect = int(kernel.REJECT_INVALID_STATE)
		case 20:
			w.subjects[0], w.subjects[1] = w.subjects[1], w.subjects[0]
			expect = int(kernel.REJECT_INVALID_STATE)
		case 21:
			hi := rand_h32(r)
			lo := rand_h32(r)
			if kernel.hash32_less(hi, lo) {
				hi, lo = lo, hi
			}
			owner := w.subjects[rand_below(r, u64(len(w.subjects)))]
			append(&w.blockmon, kernel.Blockmon_Record{hi, owner, rand_h32(r)}, kernel.Blockmon_Record{lo, owner, rand_h32(r)})
			// keep ordering the sole defect: supply still accounts for both records
			w.supply.created += 2
			w.supply.consumed += 2
			w.supply.minted += 2
			w.supply.envelope += 2
			expect = int(kernel.REJECT_INVALID_STATE)
		case 22:
			hi := rand_h32(r)
			lo := rand_h32(r)
			if kernel.hash32_less(hi, lo) {
				hi, lo = lo, hi
			}
			subj := w.subjects[rand_below(r, u64(len(w.subjects)))]
			append(
				&w.permits,
				kernel.Permit_Record{hi, subj, kernel.ENCOUNTER_COMMON, 1 + rand_below(r, 1 << 20), kernel.PERMIT_RESERVED},
				kernel.Permit_Record{lo, subj, kernel.ENCOUNTER_COMMON, 1 + rand_below(r, 1 << 20), kernel.PERMIT_RESERVED},
			)
			expect = int(kernel.REJECT_INVALID_STATE)
		case 23:
			expect = int(kernel.REJECT_INVALID_STATE)
		case 24:
			if rand_below(r, 2) == 0 {
				// record without accounting: 0xFF-fill sorts after any random id
				owner := w.subjects[rand_below(r, u64(len(w.subjects)))]
				append(&w.blockmon, kernel.Blockmon_Record{t1_fill(0xFF), owner, rand_h32(r)})
			} else {
				// accounting without a record; chain stays created <= consumed <= minted <= envelope
				w.supply.created += 1
				w.supply.consumed += 1
				w.supply.minted += 1
				w.supply.envelope += 1
			}
			expect = int(kernel.REJECT_INVALID_STATE)
		}
		ctx.entropy_round = kernel.assigned_round(ctx.position, &m)
		if class == 23 {
			// zeroed only after entropy_round is derived from the valid period
			m.round_period = 0
		}
		if class == 13 {
			if rand_below(r, 2) == 0 {
				ctx.entropy_round += 1
			} else {
				ctx.entropy_round -= 1
			}
			expect = int(kernel.REJECT_ENTROPY_MISMATCH)
		}
		transition_vec(fmt.tprintf("x-t1-%03d-%s", i, labels[class]), &w, cmd, ctx, &m, expect)
	}
}

x_reject :: proc(name, decode: string, raw: []byte) {
	assert_rejected(decode, raw)
	reject_vec(name, decode, hx(raw), "non-canonical or malformed")
}

// Truncations of a canonical top-level encoding always reject (length
// prefixes claim more than remains; fixed widths fall short), as do trailing
// bytes after a complete value. Sweep every cut for short encodings, sampled
// cuts for long ones.
x_reject_family :: proc(label, decode: string, valid: []byte) {
	n := len(valid)
	if n <= 9 {
		for t in 0 ..< n {
			x_reject(fmt.tprintf("x-reject-%s-trunc-%02d", label, t), decode, valid[:t])
		}
	} else {
		cuts := [?]int{0, 1, 2, 3, 4, n / 2, n - 1}
		for t in cuts {
			x_reject(fmt.tprintf("x-reject-%s-trunc-%02d", label, t), decode, valid[:t])
		}
	}
	trail: [dynamic]byte
	defer delete(trail)
	append(&trail, ..valid)
	append(&trail, 0x00)
	x_reject(fmt.tprintf("x-reject-%s-trail-00", label), decode, trail[:])
	trail[len(trail) - 1] = 0xFF
	x_reject(fmt.tprintf("x-reject-%s-trail-ff", label), decode, trail[:])
}

x_rejects :: proc(r: ^Rng) {
	buf: [dynamic]byte

	clear(&buf); canonical.enc_u8(&buf, u8(next_u64(r)))
	x_reject_family("u8", "u8", buf[:])
	clear(&buf); canonical.enc_u16(&buf, u16(next_u64(r)))
	x_reject_family("u16", "u16", buf[:])
	clear(&buf); canonical.enc_u32(&buf, u32(next_u64(r)))
	x_reject_family("u32", "u32", buf[:])
	clear(&buf); canonical.enc_u64(&buf, next_u64(r))
	x_reject_family("u64", "u64", buf[:])

	clear(&buf); canonical.enc_bool(&buf, false)
	x_reject_family("bool-false", "bool", buf[:])
	clear(&buf); canonical.enc_bool(&buf, true)
	x_reject_family("bool-true", "bool", buf[:])
	for b in ([]byte{2, 3, 0x7F, 0x80, 0xFE, 0xFF}) {
		x_reject(fmt.tprintf("x-reject-bool-byte-%02x", b), "bool", []byte{b})
	}

	clear(&buf); canonical.enc_enum(&buf, canonical.AUTHOR_A)
	x_reject_family("enum-author", "enum:author", buf[:])
	for b in ([]byte{0, 3, 4, 0x10, 0x7F, 0xFF}) {
		x_reject(fmt.tprintf("x-reject-enum-author-%02x", b), "enum:author", []byte{b})
	}
	clear(&buf); canonical.enc_enum(&buf, canonical.RESULT_DEFAULT)
	x_reject_family("enum-result", "enum:result", buf[:])
	for b in ([]byte{0, 4, 5, 0xFF}) {
		x_reject(fmt.tprintf("x-reject-enum-result-%02x", b), "enum:result", []byte{b})
	}

	svals := [?]string{"", "a", "abcde", "héllo⚡"}
	for s, i in svals {
		clear(&buf); canonical.enc_string(&buf, s)
		x_reject_family(fmt.tprintf("string-%d", i), "string", buf[:])
	}
	clear(&buf); canonical.enc_string(&buf, rand_ascii(r, 64))
	x_reject_family("string-4", "string", buf[:])
	// invalid UTF-8 inside well-formed length framing: lone continuation,
	// overlongs, truncated multibyte, surrogate, beyond U+10FFFF, bad leads
	bad_utf8 := [?][]byte{
		{0x80},
		{0xC0, 0x80},
		{0xC1, 0xBF},
		{0xE2, 0x82},
		{0xED, 0xA0, 0x80},
		{0xF4, 0x90, 0x80, 0x80},
		{0xFE},
		{0xFF},
		{'a', 0x80, 'z'},
	}
	for bad, i in bad_utf8 {
		clear(&buf)
		canonical.enc_u32(&buf, u32(len(bad)))
		append(&buf, ..bad)
		x_reject(fmt.tprintf("x-reject-string-utf8-%02d", i), "string", buf[:])
	}
	clear(&buf); canonical.enc_u32(&buf, 4)
	append(&buf, 'a', 'b', 'c')
	x_reject("x-reject-string-overclaim", "string", buf[:])

	blens := [?]int{0, 1, 5, 64}
	for n, i in blens {
		clear(&buf); canonical.enc_bytes(&buf, rand_bytes(r, n))
		x_reject_family(fmt.tprintf("bytes-%d", i), "bytes", buf[:])
	}
	clear(&buf); canonical.enc_u32(&buf, 6)
	append(&buf, 1, 2, 3, 4, 5)
	x_reject("x-reject-bytes-overclaim", "bytes", buf[:])

	h := rand_h32(r)
	clear(&buf); canonical.enc_hash32(&buf, h[:])
	x_reject_family("hash32", "hash32", buf[:])

	clear(&buf); canonical.enc_optional_flag(&buf, false)
	x_reject_family("optional-u64-absent", "optional:u64", buf[:])
	clear(&buf); canonical.enc_optional_flag(&buf, true)
	canonical.enc_u64(&buf, next_u64(r))
	x_reject_family("optional-u64-present", "optional:u64", buf[:])
	for b in ([]byte{2, 3, 0x80, 0xFF}) {
		flagged: [dynamic]byte
		defer delete(flagged)
		append(&flagged, b)
		canonical.enc_u64(&flagged, 7)
		x_reject(fmt.tprintf("x-reject-optional-flag-%02x", b), "optional:u64", flagged[:])
	}
	clear(&buf); canonical.enc_optional_flag(&buf, true)
	canonical.enc_bytes(&buf, []byte{9, 9})
	x_reject_family("optional-bytes", "optional:bytes", buf[:])

	sqcounts := [?]int{0, 1, 3}
	for n, i in sqcounts {
		clear(&buf)
		canonical.enc_seq_count(&buf, n)
		for _ in 0 ..< n {
			canonical.enc_u64(&buf, next_u64(r))
		}
		x_reject_family(fmt.tprintf("seq-u64-%d", i), "seq:u64", buf[:])
	}
	clear(&buf); canonical.enc_seq_count(&buf, 2)
	canonical.enc_u64(&buf, 7)
	x_reject("x-reject-seq-count-overclaim", "seq:u64", buf[:])
}

emit_expansion :: proc() {
	r := Rng{s = EXPANSION_SEED}
	emit("{{\n")
	emit("  \"spec\": \"docs/architecture/canonical-encoding.md\",\n")
	emit("  \"encoding_version\": \"v0\",\n")
	emit("  \"protocol_hash\": \"SHA-256\",\n")
	emit("  \"domain_construction\": \"sha256(u8_len(domain) || domain || payload)\",\n")
	emit("  \"tier\": \"expansion\",\n")
	emit("  \"generator_seed\": \"0x60a0ec5eed\",\n")
	emit("  \"vectors\": [\n")
	x_ints(&r)
	x_bytes_strings(&r)
	x_optionals_seqs(&r)
	x_records(&r)
	x_transcripts(&r)
	x_hashes(&r)
	x_transitions(&r)
	x_rejects(&r)
	emit("\n  ]\n}}\n")
}

main :: proc() {
	strings.builder_init(&out)

	if len(os.args) > 1 && os.args[1] == "expansion" {
		emit_expansion()
		os.write_string(os.stdout, strings.to_string(out))
		return
	}

	emit("{{\n")
	emit("  \"spec\": \"docs/architecture/canonical-encoding.md\",\n")
	emit("  \"encoding_version\": \"v0\",\n")
	emit("  \"protocol_hash\": \"SHA-256\",\n")
	emit("  \"domain_construction\": \"sha256(u8_len(domain) || domain || payload)\",\n")
	emit("  \"pairs_distinct\": [[\"ambiguity-pair-1\", \"ambiguity-pair-2\"], [\"domain-sep-op\", \"domain-sep-checkpoint\"], [\"boundary-shift-1\", \"boundary-shift-2\"], [\"transcript-slice-b\", \"transcript-reversed\"]],\n")
	emit("  \"vectors\": [\n")

	buf: [dynamic]byte

	// ---- primitives -----------------------------------------------------------
	clear(&buf); canonical.enc_u8(&buf, 0)
	encode_vec("u8-zero", "g0a", "u8", "\"0\"", buf[:])
	clear(&buf); canonical.enc_u8(&buf, 255)
	encode_vec("u8-max", "g0a", "u8", "\"255\"", buf[:])
	clear(&buf); canonical.enc_u16(&buf, 0x0102)
	encode_vec("u16-order", "g0a", "u16", "\"258\"", buf[:])
	clear(&buf); canonical.enc_u32(&buf, 0)
	encode_vec("u32-zero", "g0a", "u32", "\"0\"", buf[:])
	clear(&buf); canonical.enc_u32(&buf, max(u32))
	encode_vec("u32-max", "g0a", "u32", "\"4294967295\"", buf[:])
	clear(&buf); canonical.enc_u64(&buf, 0)
	encode_vec("u64-zero", "g0a", "u64", "\"0\"", buf[:])
	clear(&buf); canonical.enc_u64(&buf, 1)
	encode_vec("u64-one", "g0a", "u64", "\"1\"", buf[:])
	clear(&buf); canonical.enc_u64(&buf, max(u64))
	encode_vec("u64-max", "g0a", "u64", "\"18446744073709551615\"", buf[:])
	clear(&buf); canonical.enc_bool(&buf, false)
	encode_vec("bool-false", "g0a", "bool", "false", buf[:])
	clear(&buf); canonical.enc_bool(&buf, true)
	encode_vec("bool-true", "g0a", "bool", "true", buf[:])
	clear(&buf); canonical.enc_bytes(&buf, []byte{})
	encode_vec("bytes-empty", "g0a", "bytes", "\"0x\"", buf[:])
	clear(&buf); canonical.enc_bytes(&buf, []byte{1, 2, 3})
	encode_vec("bytes-3", "g0a", "bytes", "\"0x010203\"", buf[:])
	clear(&buf); canonical.enc_string(&buf, "")
	encode_vec("string-empty", "g0a", "string", "\"\"", buf[:])
	clear(&buf); canonical.enc_string(&buf, "hellope")
	encode_vec("string-ascii", "g0a", "string", "\"hellope\"", buf[:])
	clear(&buf); canonical.enc_string(&buf, "héllo⚡")
	encode_vec("string-multibyte", "g0a", "string", "\"héllo⚡\"", buf[:])

	pattern32: [32]byte
	for i in 0 ..< 32 {
		pattern32[i] = byte(i)
	}
	clear(&buf); canonical.enc_hash32(&buf, pattern32[:])
	encode_vec("hash32-pattern", "g0a", "hash32", fmt.tprintf("\"%s\"", hx(pattern32[:])), buf[:])

	clear(&buf); canonical.enc_enum(&buf, canonical.AUTHOR_A)
	encode_vec("enum-author-a", "g0a", "enum:author", "1", buf[:])
	clear(&buf); canonical.enc_enum(&buf, canonical.AUTHOR_B)
	encode_vec("enum-author-b", "g0a", "enum:author", "2", buf[:])
	clear(&buf); canonical.enc_enum(&buf, canonical.RESULT_DEFAULT)
	encode_vec("enum-result-default", "g0a", "enum:result", "3", buf[:])

	clear(&buf); canonical.enc_optional_flag(&buf, false)
	encode_vec("optional-u64-absent", "g0a", "optional:u64", "null", buf[:])
	clear(&buf); canonical.enc_optional_flag(&buf, true); canonical.enc_u64(&buf, 7)
	encode_vec("optional-u64-present", "g0a", "optional:u64", "\"7\"", buf[:])
	clear(&buf); canonical.enc_optional_flag(&buf, true); canonical.enc_bytes(&buf, []byte{})
	encode_vec("optional-bytes-present-empty", "g0a", "optional:bytes", "\"0x\"", buf[:])

	clear(&buf); canonical.enc_seq_count(&buf, 0)
	encode_vec("seq-u64-empty", "g0a", "seq:u64", "[]", buf[:])
	clear(&buf); canonical.enc_seq_count(&buf, 1); canonical.enc_u64(&buf, 7)
	encode_vec("seq-u64-one", "g0a", "seq:u64", "[\"7\"]", buf[:])
	clear(&buf); canonical.enc_seq_count(&buf, 2); canonical.enc_u64(&buf, 7); canonical.enc_u64(&buf, 8)
	encode_vec("seq-u64-two", "g0a", "seq:u64", "[\"7\", \"8\"]", buf[:])

	// ---- ambiguity pair: would collide without length prefixes ------------------
	amb1, amb2: [dynamic]byte
	canonical.enc_string(&amb1, "A"); canonical.enc_string(&amb1, "BC")
	canonical.enc_string(&amb2, "AB"); canonical.enc_string(&amb2, "C")
	h1 := canonical.protocol_hash(canonical.DOMAIN_OP, amb1[:])
	h2 := canonical.protocol_hash(canonical.DOMAIN_OP, amb2[:])
	encode_vec("ambiguity-pair-1", "g0a", "record:string2", "[\"A\", \"BC\"]", amb1[:], canonical.DOMAIN_OP, h1[:])
	encode_vec("ambiguity-pair-2", "g0a", "record:string2", "[\"AB\", \"C\"]", amb2[:], canonical.DOMAIN_OP, h2[:])

	// ---- domain separation -------------------------------------------------------
	payload := []byte{0xde, 0xad, 0xbe, 0xef}
	hash_vec("domain-sep-op", "g0a", canonical.DOMAIN_OP, payload)
	hash_vec("domain-sep-checkpoint", "g0a", canonical.DOMAIN_CHECKPOINT, payload)

	// boundary shift: naive concatenations collide ("blockmon/aa/v01bb"),
	// the u8 length prefix keeps them apart
	hash_vec("boundary-shift-1", "g0a", "blockmon/aa/v0", transmute([]byte)string("1bb"))
	hash_vec("boundary-shift-2", "g0a", "blockmon/aa/v01", transmute([]byte)string("bb"))

	// ---- Slice B transcript objects, promoted ------------------------------------
	battle_id := sha256_bytes(transmute([]byte)string("blockmon/test-battle/1"))

	op1 := canonical.Op{battle_id, 1, {}, canonical.AUTHOR_A, "move:ember"}
	op1_bytes := canonical.encode_op(op1)
	op1_h := canonical.op_hash(op1)
	op2 := canonical.Op{battle_id, 2, op1_h, canonical.AUTHOR_B, "move:splash"}
	op2_bytes := canonical.encode_op(op2)
	op2_h := canonical.op_hash(op2)

	op1_val := fmt.tprintf(
		"{{\"battle_id\": \"%s\", \"seq\": \"1\", \"prev_hash\": \"%s\", \"author\": 1, \"move\": \"move:ember\"}}",
		hx(battle_id[:]), hx(make([]byte, 32)),
	)
	encode_vec("op-slice-b-1", "slice-b", "record:op", op1_val, op1_bytes[:], canonical.DOMAIN_OP, op1_h[:])
	op2_val := fmt.tprintf(
		"{{\"battle_id\": \"%s\", \"seq\": \"2\", \"prev_hash\": \"%s\", \"author\": 2, \"move\": \"move:splash\"}}",
		hx(battle_id[:]), hx(op1_h[:]),
	)
	encode_vec("op-slice-b-2", "slice-b", "record:op", op2_val, op2_bytes[:], canonical.DOMAIN_OP, op2_h[:])

	// transcript chain vectors: prev hashes derived by the checker, not given
	vec_open("transcript-slice-b", "transcript", "slice-b")
	emit(
		", \"battle_id\": \"%s\", \"ops\": [{{\"author\": 1, \"move\": \"move:ember\"}}, {{\"author\": 2, \"move\": \"move:splash\"}}], \"head\": \"%s\"",
		hx(battle_id[:]), hx(op2_h[:]),
	)
	vec_close()

	r1 := canonical.Op{battle_id, 1, {}, canonical.AUTHOR_B, "move:splash"}
	r1_h := canonical.op_hash(r1)
	r2 := canonical.Op{battle_id, 2, r1_h, canonical.AUTHOR_A, "move:ember"}
	r2_h := canonical.op_hash(r2)
	vec_open("transcript-reversed", "transcript", "g0a")
	emit(
		", \"battle_id\": \"%s\", \"ops\": [{{\"author\": 2, \"move\": \"move:splash\"}}, {{\"author\": 1, \"move\": \"move:ember\"}}], \"head\": \"%s\"",
		hx(battle_id[:]), hx(r2_h[:]),
	)
	vec_close()

	ck := canonical.Checkpoint{battle_id, 2, op2_h, canonical.RESULT_A_WINS}
	ck_bytes := canonical.encode_checkpoint(ck)
	ck_h := canonical.checkpoint_hash(ck)
	ck_val := fmt.tprintf(
		"{{\"battle_id\": \"%s\", \"seq\": \"2\", \"transcript_head\": \"%s\", \"result\": 1}}",
		hx(battle_id[:]), hx(op2_h[:]),
	)
	encode_vec("checkpoint-slice-b", "slice-b", "record:checkpoint", ck_val, ck_bytes[:], canonical.DOMAIN_CHECKPOINT, ck_h[:])

	sc := canonical.state_commitment(op2_h, canonical.RESULT_A_WINS)
	st_buf: [dynamic]byte
	canonical.enc_hash32(&st_buf, op2_h[:])
	canonical.enc_enum(&st_buf, canonical.RESULT_A_WINS)
	st_val := fmt.tprintf("{{\"transcript_head\": \"%s\", \"result\": 1}}", hx(op2_h[:]))
	encode_vec("state-slice-b", "slice-b", "record:state", st_val, st_buf[:], canonical.DOMAIN_STATE, sc[:])

	// ---- Transition 1 kernel-backed vectors ------------------------------------------
	emit_transition_vectors()

	// ---- rejection vectors ---------------------------------------------------------
	rejects := [][3]string{
		{"reject-bool-2", "bool", "0x02"},
		{"reject-enum-author-3", "enum:author", "0x03"},
		{"reject-enum-author-0", "enum:author", "0x00"},
		{"reject-string-bad-utf8", "string", "0x00000001ff"},
		{"reject-string-truncated", "string", "0x00000005616263"},
		{"reject-u64-trailing", "u64", "0x000000000000000700"},
		{"reject-optional-flag-2", "optional:u64", "0x020000000000000007"},
	}
	for rj in rejects {
		raw, ok := hex.decode(transmute([]byte)rj[2][2:])
		if !ok {
			fmt.eprintln("bad reject hex:", rj[0])
			os.exit(1)
		}
		assert_rejected(rj[1], raw)
		reject_vec(rj[0], rj[1], rj[2], "non-canonical or malformed")
	}

	emit("\n  ]\n}}\n")
	os.write_string(os.stdout, strings.to_string(out))
}
