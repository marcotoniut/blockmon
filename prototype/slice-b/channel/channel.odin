// Battle-channel participant adapter for the Slice B dual-process run
// (prototype-and-technology.md §2.2). Not a game client, not a networking
// layer: the smallest driver that lets two separate OS processes execute one
// battle channel over a loopback socket.
//
// Shared by player-a, player-b and the single-process probe so the channel key
// schedule, transcript construction and checkpoint representation exist once.
// This package holds no key seeds: every secret enters through Config, which
// each player program fills from its own compiled-in material.
//
// Protocol-visible bytes (ops, checkpoints, state commitment) come from
// protocol/canonical. Frame headers and the hello frame are transport
// scaffolding outside canonical-encoding.md's scope, which owns
// protocol-visible values only.
package channel

import canonical "../../../protocol/canonical"

import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// ---- channel-layer domain separation (battle-channel.md §3) -----------------
// Info strings, not canonical-encoding.md §3 domains: these are layer-2
// battle-channel cryptography and deliberately not consensus-visible.

KDF_INFO :: "blockmon/battle/v0"
INFO_TRANSPORT :: "blockmon/battle/transport/v0"
INFO_HIDDEN :: "blockmon/battle/hidden-state/v0"
INFO_SESSION_CHECK :: "blockmon/battle/session-check/v0"
HELLO_TAG :: "blockmon/battle/hello/v0"

// ---- representative exchange (the test ruleset's two ops) -------------------

MOVE_A :: "move:ember"
MOVE_B :: "move:splash"

// ---- transport -------------------------------------------------------------

FRAME_HELLO :: u8(1)
FRAME_OP :: u8(2)
FRAME_CKSIG :: u8(3)
FRAME_DONE :: u8(4)

MAX_FRAME :: 4096
SIG_SIZE :: ed25519.SIGNATURE_SIZE

// The counterparty process is started by hand in the manual flow, so the
// transport handshake gets a human-scale budget; frames between two running
// programs get a short one. The automated harness bounds a deadlock sooner.
CONNECT_TIMEOUT :: 120 * time.Second
CONNECT_POLL :: 200 * time.Millisecond
CONNECT_ATTEMPTS :: int(CONNECT_TIMEOUT / CONNECT_POLL)

RECV_TIMEOUT :: 10 * time.Second

Role :: enum {
	A,
	B,
}

Config :: struct {
	role:    Role,
	seed_ed: [32]byte,
	seed_x:  [32]byte,
}

// Public battle state, mirrored from the anchor venue by the harness. Every
// field is public; a participant learns nothing about its counterparty here
// beyond what the anchor venue records, and checks all of it against the venue.
Descriptor :: struct {
	battle_id:          string,
	ruleset_hash:       string,
	ed_pk_a:            string,
	x_pk_a:             string,
	ed_pk_b:            string,
	x_pk_b:             string,
	player_a_wallet:    string,
	player_b_wallet:    string,
	contract:           string,
	rpc_host:           string,
	rpc_port:           int,
	transport_host:     string,
	transport_port:     int,
	transport_listener: string,
}

Session :: struct {
	k_battle:  [32]byte,
	// Retained as Slice B evidence that purpose keys derive from K_battle under
	// domain separation (battle-channel.md §3). No participant consumes them
	// yet; the probe emits them as vectors.
	transport: [32]byte,
	hidden:    [32]byte,
	check:     [32]byte, // agreement witness; the secret itself never leaves
}

// The descriptor's claims, decoded once. Everything here is checked against the
// anchor venue by verify_anchored before the battle counts as joined.
Claims :: struct {
	battle_id:    [32]byte,
	ruleset_hash: [32]byte,
	wallet_a:     [20]byte,
	wallet_b:     [20]byte,
	ed_pk_a:      [32]byte,
	x_pk_a:       [32]byte,
	ed_pk_b:      [32]byte,
	x_pk_b:       [32]byte,
}

Local_Op :: struct {
	seq:     u64,
	author:  u8,
	move:    string,
	op_hash: [32]byte,
}

// What a participant independently derived, and can be held to. The harness
// compares the two sides' copies; nothing here is taken on the peer's word.
Evidence :: struct {
	role:             string,
	battle_id:        [32]byte,
	ruleset_hash:     [32]byte,
	peer_ed_pk:       [32]byte,
	session_check:    [32]byte,
	ops:              [2]Local_Op,
	transcript_head:  [32]byte,
	final_seq:        u64,
	result:           u8,
	state_commitment: [32]byte,
	checkpoint_hash:  [32]byte,
	ck_sig_self:      [SIG_SIZE]byte,
	ck_sig_peer:      [SIG_SIZE]byte,
}

Conn :: struct {
	sock: net.TCP_Socket,
	log:  [dynamic]string,
}

// ---- derivation (battle-channel.md §3) --------------------------------------

ed_private :: proc(seed: [32]byte) -> ed25519.Private_Key {
	seed := seed
	key: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&key, seed[:]) {
		die("ed25519 seed rejected")
	}
	return key
}

ed_public :: proc(key: ^ed25519.Private_Key) -> [32]byte {
	out: [32]byte
	ed25519.private_key_public_bytes(key, out[:])
	return out
}

x_public :: proc(seed: [32]byte) -> [32]byte {
	seed := seed
	out: [32]byte
	x25519.scalarmult_basepoint(out[:], seed[:])
	return out
}

derive_session :: proc(battle_id, seed_x_self, x_pk_peer: [32]byte) -> Session {
	battle_id, seed, peer := battle_id, seed_x_self, x_pk_peer
	dh: [32]byte
	x25519.scalarmult(dh[:], seed[:], peer[:])

	s: Session
	hkdf.extract_and_expand(
		hash.Algorithm.SHA256,
		battle_id[:],
		dh[:],
		transmute([]byte)string(KDF_INFO),
		s.k_battle[:],
	)
	hkdf.expand(hash.Algorithm.SHA256, s.k_battle[:], transmute([]byte)string(INFO_TRANSPORT), s.transport[:])
	hkdf.expand(hash.Algorithm.SHA256, s.k_battle[:], transmute([]byte)string(INFO_HIDDEN), s.hidden[:])
	hkdf.expand(hash.Algorithm.SHA256, s.k_battle[:], transmute([]byte)string(INFO_SESSION_CHECK), s.check[:])
	return s
}

// Test ruleset, deliberately trivial: ember beats splash, anything else is the
// default outcome. Both participants evaluate it locally; neither is told.
resolve_result :: proc(move_1, move_2: string) -> u8 {
	if move_1 == MOVE_A && move_2 == MOVE_B {
		return canonical.RESULT_A_WINS
	}
	return canonical.RESULT_DEFAULT
}

result_name :: proc(result: u8) -> string {
	switch result {
	case canonical.RESULT_A_WINS:
		return "A_WINS"
	case canonical.RESULT_B_WINS:
		return "B_WINS"
	}
	return "DEFAULT"
}

// ---- entry point -----------------------------------------------------------

run :: proc(cfg: Config) {
	args := os.args
	if len(args) >= 2 && args[1] == "keys" {
		emit_keys(cfg)
		return
	}
	if len(args) == 4 && args[1] == "play" {
		play(cfg, args[2], args[3])
		return
	}
	fmt.eprintfln("usage: %s keys | %s play <battle-descriptor.json> <run-dir>", args[0], args[0])
	os.exit(2)
}

emit_keys :: proc(cfg: Config) {
	ed := ed_private(cfg.seed_ed)
	ed_pk := ed_public(&ed)
	x_pk := x_public(cfg.seed_x)
	fmt.printfln(
		"{{\"role\": \"%s\", \"ed_pk\": \"0x%s\", \"x_pk\": \"0x%s\"}}",
		letter(cfg.role),
		hex_str(ed_pk[:]),
		hex_str(x_pk[:]),
	)
}

play :: proc(cfg: Config, descriptor_path, run_dir: string) {
	d := load_descriptor(descriptor_path)
	self, peer := letter(cfg.role), letter(other(cfg.role))
	author, peer_author := author_of(cfg.role), author_of(other(cfg.role))

	claims := parse_claims(d)
	battle_id, ruleset := claims.battle_id, claims.ruleset_hash
	anchored_ed_self := claims.ed_pk_a if cfg.role == .A else claims.ed_pk_b
	anchored_x_self := claims.x_pk_a if cfg.role == .A else claims.x_pk_b
	anchored_ed_peer := claims.ed_pk_b if cfg.role == .A else claims.ed_pk_a
	anchored_x_peer := claims.x_pk_b if cfg.role == .A else claims.x_pk_a

	ed_self := ed_private(cfg.seed_ed)
	ed_pk_self := ed_public(&ed_self)
	x_pk_self := x_public(cfg.seed_x)

	fmt.printfln("PLAYER %s", strings.to_upper(self))
	fmt.printfln("battle:     0x%s", hex_str(battle_id[:]))
	fmt.printfln("ruleset:    0x%s", hex_str(ruleset[:]))

	verify_anchored(d, claims)
	fmt.printfln("anchored:   ruleset, participants and both keys read from %s:%d", d.rpc_host, d.rpc_port)

	if anchored_ed_self != ed_pk_self || anchored_x_self != x_pk_self {
		die("the keys anchored for %s are not this process's ephemeral keys", self)
	}
	fmt.printfln("joined:     anchored keys for %s are this process's own", self)

	conn := connect(d, self)
	defer net.close(conn.sock)

	// --- hello: proof of possession over the anchored keys -------------------
	hello := encode_hello(author, battle_id, ruleset, ed_pk_self, x_pk_self)
	hello_sig: [SIG_SIZE]byte
	ed25519.sign(&ed_self, tagged(HELLO_TAG, hello[:]), hello_sig[:])
	send_frame(&conn, FRAME_HELLO, join(hello[:], hello_sig[:]))

	peer_hello := expect_frame(&conn, FRAME_HELLO, "hello")
	body, peer_hello_sig := split_sig(peer_hello, "hello")
	h, herr := decode_hello(body)
	if herr != .None {
		die("peer hello is not canonical: %v", herr)
	}
	if h.author != peer_author {
		die("peer hello claims author %d, expected %d", h.author, peer_author)
	}
	if h.battle_id != battle_id || h.ruleset_hash != ruleset {
		die("peer hello is bound to a different battle or ruleset")
	}
	if h.ed_pk != anchored_ed_peer || h.x_pk != anchored_x_peer {
		die("peer presented keys that are not anchored for %s", peer)
	}
	if !ed25519_verify(anchored_ed_peer, tagged(HELLO_TAG, body), peer_hello_sig) {
		die("peer hello signature does not verify under the anchored key")
	}
	fmt.printfln("peer:       %s authenticated, ed 0x%s", peer, hex_str(anchored_ed_peer[:]))

	// --- session secret, from own secret and the peer's anchored key ---------
	sess := derive_session(battle_id, cfg.seed_x, anchored_x_peer)
	fmt.printfln("session:    established, check 0x%s", hex_str(sess.check[:4]))

	// --- representative exchange, strictly alternating -----------------------
	ops: [2]Local_Op
	head: [32]byte // genesis prev = 0x00..00 (canonical-encoding.md §4)
	for i in 0 ..< 2 {
		seq := u64(i + 1)
		mover := canonical.AUTHOR_A if i == 0 else canonical.AUTHOR_B
		move := MOVE_A if i == 0 else MOVE_B

		if mover == author {
			op := canonical.Op{battle_id, seq, head, author, move}
			bytes := canonical.encode_op(op)
			defer delete(bytes)
			sig: [SIG_SIZE]byte
			ed25519.sign(&ed_self, bytes[:], sig[:])
			send_frame(&conn, FRAME_OP, join(bytes[:], sig[:]))
			ops[i] = Local_Op{seq, author, move, canonical.op_hash(op)}
			fmt.printfln("op %d:       sent     %s", seq, move)
		} else {
			payload := expect_frame(&conn, FRAME_OP, "op")
			op_bytes, sig := split_sig(payload, "op")
			op, err := decode_op(op_bytes)
			if err != .None {
				die("op %d is not canonical: %v", seq, err)
			}
			if op.battle_id != battle_id {
				die("op %d is bound to a different battle", seq)
			}
			if op.seq != seq {
				die("op sequence: expected %d, received %d", seq, op.seq)
			}
			if op.prev_hash != head {
				die("op %d does not chain to the local transcript head", seq)
			}
			if op.author != mover {
				die("op %d author %d is not the counterparty", seq, op.author)
			}
			if !ed25519_verify(anchored_ed_peer, op_bytes, sig) {
				die("op %d signature does not verify under the anchored key", seq)
			}
			ops[i] = Local_Op{seq, op.author, op.move, canonical.op_hash(op)}
			fmt.printfln("op %d:       accepted %s", seq, op.move)
		}
		head = ops[i].op_hash
	}

	// --- final checkpoint, dual-signed --------------------------------------
	result := resolve_result(ops[0].move, ops[1].move)
	final_seq := ops[1].seq
	commitment := canonical.state_commitment(head, result)
	ck := canonical.Checkpoint{battle_id, final_seq, head, result}
	ck_bytes := canonical.encode_checkpoint(ck)
	defer delete(ck_bytes)
	ck_hash := canonical.checkpoint_hash(ck)

	sig_self: [SIG_SIZE]byte
	ed25519.sign(&ed_self, ck_bytes[:], sig_self[:])
	send_frame(&conn, FRAME_CKSIG, join(ck_bytes[:], sig_self[:]))

	peer_ck := expect_frame(&conn, FRAME_CKSIG, "checkpoint signature")
	peer_ck_bytes, sig_peer_slice := split_sig(peer_ck, "checkpoint signature")
	if !slice.equal(peer_ck_bytes, ck_bytes[:]) {
		die("peer signed a different checkpoint than the local one")
	}
	if !ed25519_verify(anchored_ed_peer, ck_bytes[:], sig_peer_slice) {
		die("peer checkpoint signature does not verify under the anchored key")
	}
	ev := Evidence {
		role             = self,
		battle_id        = battle_id,
		ruleset_hash     = ruleset,
		peer_ed_pk       = anchored_ed_peer,
		session_check    = sess.check,
		ops              = ops,
		transcript_head  = head,
		final_seq        = final_seq,
		result           = result,
		state_commitment = commitment,
		checkpoint_hash  = ck_hash,
		ck_sig_self      = sig_self,
	}
	copy(ev.ck_sig_peer[:], sig_peer_slice)

	fmt.printfln("head:       0x%s", hex_str(head[:]))
	fmt.printfln("checkpoint: seq %d result %s state 0x%s", final_seq, result_name(result), hex_str(commitment[:]))
	fmt.printfln("authorised: dual-signed by %s and %s", self, peer)

	send_frame(&conn, FRAME_DONE, nil)
	_ = expect_frame(&conn, FRAME_DONE, "done")

	// Wire log first: the harness treats session-<role>.json appearing as the
	// signal that this participant's artefacts are all complete.
	write_wire_log(&conn, fmt.tprintf("%s/wire-%s.log", run_dir, self))
	write_session(fmt.tprintf("%s/session-%s.json", run_dir, self), ev)

	// --- settlement, read from the anchor venue by this process --------------
	s := await_settlement(d, battle_id)
	if s.state_commitment != commitment {
		die("the settled state commitment is not the one this process derived")
	}
	if s.result != result || s.final_seq != final_seq {
		die("settled result %d seq %d disagrees with local %d seq %d", s.result, s.final_seq, result, final_seq)
	}
	fmt.printfln("settled:    %s (seq %d), as recorded on chain", result_name(result), final_seq)
}

// ---- transport -------------------------------------------------------------

connect :: proc(d: Descriptor, self: string) -> Conn {
	addr := net.parse_address(d.transport_host)
	if addr == nil {
		die("transport host %q is not an address", d.transport_host)
	}
	ep := net.Endpoint {
		address = addr,
		port    = d.transport_port,
	}

	// Which side listens is transport bookkeeping carried in the descriptor,
	// not a protocol asymmetry: the channel itself is symmetric.
	sock: net.TCP_Socket
	if d.transport_listener == self {
		listener, lerr := net.listen_tcp(ep)
		if lerr != nil {
			die("listen on %s:%d: %v", d.transport_host, d.transport_port, lerr)
		}
		defer net.close(listener)
		fmt.printfln("transport:  listening on %s:%d", d.transport_host, d.transport_port)
		sock = accept_bounded(listener, d)
	} else {
		fmt.printfln("transport:  dialling %s:%d", d.transport_host, d.transport_port)
		sock = dial_bounded(ep, d)
	}

	set_recv_timeout(sock)
	nodelay := true
	_ = net.set_option(sock, .TCP_Nodelay, nodelay)
	return Conn{sock = sock}
}

// A receive timeout does not bound accept() on every platform, so the listener
// polls a non-blocking socket instead of trusting the option.
accept_bounded :: proc(listener: net.TCP_Socket, d: Descriptor) -> net.TCP_Socket {
	if err := net.set_blocking(listener, false); err != .None {
		die("set listener non-blocking: %v", err)
	}
	for _ in 1 ..= CONNECT_ATTEMPTS {
		client, _, aerr := net.accept_tcp(listener)
		if aerr == .None {
			if err := net.set_blocking(client, true); err != .None {
				die("set accepted socket blocking: %v", err)
			}
			return client
		}
		if aerr != .Would_Block && aerr != .Timeout {
			die("accept on %s:%d: %v", d.transport_host, d.transport_port, aerr)
		}
		time.sleep(CONNECT_POLL)
	}
	die("no counterparty connected on %s:%d within %v", d.transport_host, d.transport_port, CONNECT_TIMEOUT)
}

dial_bounded :: proc(ep: net.Endpoint, d: Descriptor) -> net.TCP_Socket {
	for _ in 1 ..= CONNECT_ATTEMPTS {
		sock, derr := net.dial_tcp_from_endpoint(ep)
		if derr == nil {
			return sock
		}
		time.sleep(CONNECT_POLL)
	}
	die("no counterparty listening on %s:%d within %v", d.transport_host, d.transport_port, CONNECT_TIMEOUT)
}

set_recv_timeout :: proc(sock: net.TCP_Socket) {
	t := RECV_TIMEOUT
	if err := net.set_option(sock, .Receive_Timeout, t); err != .None {
		die("set receive timeout: %v", err)
	}
}

send_frame :: proc(c: ^Conn, kind: u8, payload: []byte) {
	if len(payload) > MAX_FRAME {
		die("outgoing frame of %d bytes exceeds the %d-byte limit", len(payload), MAX_FRAME)
	}
	n := u32(len(payload))
	header := [5]byte{kind, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)}
	if err := send_all(c.sock, join(header[:], payload)); err != .None {
		if err == .Connection_Closed || err == .Not_Connected {
			die("the counterparty closed the connection before frame kind %d could be sent", kind)
		}
		die("sending frame kind %d failed: %v", kind, err)
	}
	log_frame(c, ">", kind, payload)
}

expect_frame :: proc(c: ^Conn, want: u8, what: string) -> []byte {
	kind, payload := recv_frame(c, what)
	if kind != want {
		die("expected %s (kind %d), received kind %d", what, want, kind)
	}
	return payload
}

recv_frame :: proc(c: ^Conn, what: string) -> (u8, []byte) {
	header: [5]byte
	expect_bytes(recv_all(c.sock, header[:]), what)
	n := int(u32(header[1]) << 24 | u32(header[2]) << 16 | u32(header[3]) << 8 | u32(header[4]))
	if n > MAX_FRAME {
		die("incoming frame of %d bytes exceeds the %d-byte limit", n, MAX_FRAME)
	}
	payload := make([]byte, n)
	if n > 0 {
		expect_bytes(recv_all(c.sock, payload), what)
	}
	log_frame(c, "<", header[0], payload)
	return header[0], payload
}

// A dead counterparty and a silent one are different failures and must not
// report as each other: only one of them is a protocol deadlock.
expect_bytes :: proc(err: net.TCP_Recv_Error, what: string) {
	#partial switch err {
	case .None:
	case .Connection_Closed:
		die("the counterparty closed the connection while sending %s", what)
	case .Timeout, .Would_Block:
		die("no %s arrived within %v", what, RECV_TIMEOUT)
	case:
		die("reading %s failed: %v", what, err)
	}
}

send_all :: proc(sock: net.TCP_Socket, buf: []byte) -> net.TCP_Send_Error {
	for off := 0; off < len(buf); {
		n, err := net.send_tcp(sock, buf[off:])
		if err != .None {
			return err
		}
		if n <= 0 {
			return .Unknown
		}
		off += n
	}
	return .None
}

recv_all :: proc(sock: net.TCP_Socket, buf: []byte) -> net.TCP_Recv_Error {
	for off := 0; off < len(buf); {
		n, err := net.recv_tcp(sock, buf[off:])
		if err != .None {
			return err
		}
		if n == 0 {
			return .Connection_Closed
		}
		off += n
	}
	return .None
}

log_frame :: proc(c: ^Conn, dir: string, kind: u8, payload: []byte) {
	append(&c.log, fmt.aprintf("%s %02x %s", dir, kind, hex_str(payload)))
}

write_wire_log :: proc(c: ^Conn, path: string) {
	b := strings.builder_make()
	for line in c.log {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	write_file(path, strings.to_string(b))
}

// ---- frame bodies ----------------------------------------------------------

Hello :: struct {
	author:       u8,
	battle_id:    [32]byte,
	ruleset_hash: [32]byte,
	ed_pk:        [32]byte,
	x_pk:         [32]byte,
}

encode_hello :: proc(author: u8, battle_id, ruleset_hash, ed_pk, x_pk: [32]byte) -> [dynamic]byte {
	battle_id, ruleset_hash, ed_pk, x_pk := battle_id, ruleset_hash, ed_pk, x_pk
	buf: [dynamic]byte
	canonical.enc_enum(&buf, author)
	canonical.enc_hash32(&buf, battle_id[:])
	canonical.enc_hash32(&buf, ruleset_hash[:])
	canonical.enc_hash32(&buf, ed_pk[:])
	canonical.enc_hash32(&buf, x_pk[:])
	return buf
}

decode_hello :: proc(data: []byte) -> (Hello, canonical.Decode_Error) {
	r := canonical.Reader{data = data}
	h: Hello
	err: canonical.Decode_Error

	h.author, err = canonical.dec_enum(&r, []u8{canonical.AUTHOR_A, canonical.AUTHOR_B})
	if err != .None {
		return h, err
	}
	for dst in ([]^[32]byte{&h.battle_id, &h.ruleset_hash, &h.ed_pk, &h.x_pk}) {
		b, e := canonical.read_exact(&r, 32)
		if e != .None {
			return h, e
		}
		copy(dst[:], b)
	}
	return h, canonical.finish(&r)
}

decode_op :: proc(data: []byte) -> (canonical.Op, canonical.Decode_Error) {
	r := canonical.Reader{data = data}
	op: canonical.Op

	id, err := canonical.read_exact(&r, 32)
	if err != .None {
		return op, err
	}
	copy(op.battle_id[:], id)

	op.seq, err = canonical.dec_u64(&r)
	if err != .None {
		return op, err
	}

	prev, perr := canonical.read_exact(&r, 32)
	if perr != .None {
		return op, perr
	}
	copy(op.prev_hash[:], prev)

	op.author, err = canonical.dec_enum(&r, []u8{canonical.AUTHOR_A, canonical.AUTHOR_B})
	if err != .None {
		return op, err
	}
	op.move, err = canonical.dec_string(&r)
	if err != .None {
		return op, err
	}
	return op, canonical.finish(&r)
}

// Signature frames are body ‖ 64-byte signature; the body length is whatever
// precedes it, and strict decoding rejects any body that is not canonical.
split_sig :: proc(payload: []byte, what: string) -> ([]byte, []byte) {
	if len(payload) <= SIG_SIZE {
		die("%s frame of %d bytes carries no signed body", what, len(payload))
	}
	cut := len(payload) - SIG_SIZE
	return payload[:cut], payload[cut:]
}

tagged :: proc(tag: string, body: []byte) -> []byte {
	return join(transmute([]byte)tag, body)
}

ed25519_verify :: proc(pk_bytes: [32]byte, msg, sig: []byte) -> bool {
	pk_bytes := pk_bytes
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, pk_bytes[:]) {
		return false
	}
	return ed25519.verify(&pk, msg, sig)
}

// ---- run artefacts ---------------------------------------------------------

write_session :: proc(path: string, ev: Evidence) {
	e := ev
	b := strings.builder_make()
	fmt.sbprintf(&b, "{{\n")
	fmt.sbprintf(&b, "  \"role\": \"%s\",\n", e.role)
	fmt.sbprintf(&b, "  \"battle_id\": \"0x%s\",\n", hex_str(e.battle_id[:]))
	fmt.sbprintf(&b, "  \"ruleset_hash\": \"0x%s\",\n", hex_str(e.ruleset_hash[:]))
	fmt.sbprintf(&b, "  \"peer_ed_pk\": \"0x%s\",\n", hex_str(e.peer_ed_pk[:]))
	fmt.sbprintf(&b, "  \"session_check\": \"0x%s\",\n", hex_str(e.session_check[:]))
	fmt.sbprintf(&b, "  \"ops\": [\n")
	for op, i in e.ops {
		op := op
		comma := "," if i + 1 < len(e.ops) else ""
		fmt.sbprintf(
			&b,
			"    {{\"seq\": %d, \"author\": %d, \"move\": \"%s\", \"op_hash\": \"0x%s\"}}%s\n",
			op.seq,
			op.author,
			op.move,
			hex_str(op.op_hash[:]),
			comma,
		)
	}
	fmt.sbprintf(&b, "  ],\n")
	fmt.sbprintf(&b, "  \"transcript_head\": \"0x%s\",\n", hex_str(e.transcript_head[:]))
	fmt.sbprintf(&b, "  \"final_seq\": %d,\n", e.final_seq)
	fmt.sbprintf(&b, "  \"result\": %d,\n", e.result)
	fmt.sbprintf(&b, "  \"state_commitment\": \"0x%s\",\n", hex_str(e.state_commitment[:]))
	fmt.sbprintf(&b, "  \"checkpoint_hash\": \"0x%s\",\n", hex_str(e.checkpoint_hash[:]))
	fmt.sbprintf(&b, "  \"ck_sig_self\": \"0x%s\",\n", hex_str(e.ck_sig_self[:]))
	fmt.sbprintf(&b, "  \"ck_sig_peer\": \"0x%s\"\n", hex_str(e.ck_sig_peer[:]))
	fmt.sbprintf(&b, "}}\n")
	write_file(path, strings.to_string(b))
}

parse_claims :: proc(d: Descriptor) -> Claims {
	return Claims {
		battle_id = must_hex32(d.battle_id, "battle_id"),
		ruleset_hash = must_hex32(d.ruleset_hash, "ruleset_hash"),
		wallet_a = must_addr20(d.player_a_wallet, "player_a_wallet"),
		wallet_b = must_addr20(d.player_b_wallet, "player_b_wallet"),
		ed_pk_a = must_hex32(d.ed_pk_a, "ed_pk_a"),
		x_pk_a = must_hex32(d.x_pk_a, "x_pk_a"),
		ed_pk_b = must_hex32(d.ed_pk_b, "ed_pk_b"),
		x_pk_b = must_hex32(d.x_pk_b, "x_pk_b"),
	}
}

load_descriptor :: proc(path: string) -> Descriptor {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		die("cannot read battle descriptor %s: %v", path, err)
	}
	d: Descriptor
	if uerr := json.unmarshal(data, &d); uerr != nil {
		die("battle descriptor %s is not readable: %v", path, uerr)
	}
	if d.transport_port <= 0 {
		die("battle descriptor %s carries no transport port", path)
	}
	return d
}

// Through a temporary and renamed: the harness polls for these files and must
// never read a half-written one.
write_file :: proc(path, contents: string) {
	tmp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(tmp, transmute([]byte)contents); err != nil {
		die("cannot write %s: %v", tmp, err)
	}
	if err := os.rename(tmp, path); err != nil {
		die("cannot rename %s to %s: %v", tmp, path, err)
	}
}

// ---- small helpers ---------------------------------------------------------

other :: proc(role: Role) -> Role {
	return .B if role == .A else .A
}

letter :: proc(role: Role) -> string {
	return "a" if role == .A else "b"
}

author_of :: proc(role: Role) -> u8 {
	return canonical.AUTHOR_A if role == .A else canonical.AUTHOR_B
}

hex_str :: proc(b: []byte) -> string {
	s, _ := hex.encode(b)
	return string(s)
}

must_hex :: proc(s, what: string, n: int) -> []byte {
	t := strings.trim_prefix(s, "0x")
	if len(t) != n * 2 {
		die("%s is not %d hex-encoded bytes: %q", what, n, s)
	}
	raw, ok := hex.decode(transmute([]byte)t)
	if !ok || len(raw) != n {
		die("%s is not hex: %q", what, s)
	}
	return raw
}

must_hex32 :: proc(s, what: string) -> [32]byte {
	out: [32]byte
	copy(out[:], must_hex(s, what, 32))
	return out
}

join :: proc(parts: ..[]byte) -> []byte {
	total := 0
	for p in parts {
		total += len(p)
	}
	out := make([]byte, total)
	off := 0
	for p in parts {
		copy(out[off:], p)
		off += len(p)
	}
	return out
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("FAIL  ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
