// Read-only chain access for a battle participant. Signing at the settlement
// boundary may be delegated; reading settled state may not (architecture.md
// §21), so a participant needs this to check the anchored battle and the
// recorded outcome for itself instead of trusting a report of either.
//
// The smallest thing that does that: one contract, three pinned selectors,
// fixed-width word extraction, one hard-coded JSON-RPC request shape.
// Deliberately not an RPC client and not an ABI layer
// (prototype-and-technology.md §2.2).
package channel

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"

// keccak256(signature)[0:4]. Ethereum Keccak-256 stays out of Odin
// (architecture.md §21), so these are pinned and battle.sh asserts each one
// against `cast sig`.
SEL_BINDING_OF :: "0x17530ef1" // bindingOf(bytes32)
SEL_KEYS_OF :: "0x8ff91641" // keysOf(bytes32,address)
SEL_RESULT_OF :: "0x21100a74" // resultOf(bytes32)

// Address arguments occupy a full 32-byte word, left-padded.
ADDR_PAD :: "000000000000000000000000"

STATUS_SETTLED :: u8(3)

SETTLEMENT_TIMEOUT :: 30 * time.Second
SETTLEMENT_POLL :: 200 * time.Millisecond
SETTLEMENT_ATTEMPTS :: int(SETTLEMENT_TIMEOUT / SETTLEMENT_POLL)

Binding :: struct {
	player_a:     [20]byte,
	player_b:     [20]byte,
	ruleset_hash: [32]byte,
}

Anchored_Keys :: struct {
	ed_pk:      [32]byte,
	x_pk:       [32]byte,
	registered: bool,
}

Settlement :: struct {
	status:           u8,
	result:           u8,
	final_seq:        u64,
	state_commitment: [32]byte,
}

// ---- what a participant checks ---------------------------------------------

// The descriptor is a joining instruction, never evidence
// (battle-channel.md §3): everything it claims is checked here against the
// anchor venue before the battle counts as joined.
verify_anchored :: proc(d: Descriptor, c: Claims) {
	b := chain_binding(d, c.battle_id)
	if b.ruleset_hash != c.ruleset_hash {
		anchored := b.ruleset_hash
		die("anchored ruleset 0x%s is not the one this battle was joined under", hex_str(anchored[:]))
	}
	if b.player_a != c.wallet_a || b.player_b != c.wallet_b {
		die("the anchored participants are not the ones in the battle descriptor")
	}

	sides := [2]struct {
		who:    string,
		wallet: [20]byte,
		ed_pk:  [32]byte,
		x_pk:   [32]byte,
	}{{"a", c.wallet_a, c.ed_pk_a, c.x_pk_a}, {"b", c.wallet_b, c.ed_pk_b, c.x_pk_b}}
	for side in sides {
		k := chain_keys(d, c.battle_id, side.wallet)
		if !k.registered {
			die("no ephemeral keys are anchored for %s", side.who)
		}
		if k.ed_pk != side.ed_pk || k.x_pk != side.x_pk {
			die("the keys anchored for %s are not the ones in the battle descriptor", side.who)
		}
	}
}

await_settlement :: proc(d: Descriptor, battle_id: [32]byte) -> Settlement {
	for _ in 1 ..= SETTLEMENT_ATTEMPTS {
		s := chain_settlement(d, battle_id)
		if s.status == STATUS_SETTLED {
			return s
		}
		time.sleep(SETTLEMENT_POLL)
	}
	die("the battle was not settled at the anchor venue within %v", SETTLEMENT_TIMEOUT)
}

// ---- the three reads -------------------------------------------------------

chain_binding :: proc(d: Descriptor, battle_id: [32]byte) -> Binding {
	battle_id := battle_id
	out := eth_call(d, fmt.tprintf("%s%s", SEL_BINDING_OF, hex_str(battle_id[:])))
	return Binding {
		player_a     = word_addr(out, 0),
		player_b     = word_addr(out, 1),
		ruleset_hash = word_hash32(out, 2),
	}
}

chain_keys :: proc(d: Descriptor, battle_id: [32]byte, wallet: [20]byte) -> Anchored_Keys {
	battle_id, addr := battle_id, wallet
	out := eth_call(
		d,
		fmt.tprintf("%s%s%s%s", SEL_KEYS_OF, hex_str(battle_id[:]), ADDR_PAD, hex_str(addr[:])),
	)
	return Anchored_Keys {
		ed_pk      = word_hash32(out, 0),
		x_pk       = word_hash32(out, 1),
		registered = word_bool(out, 2),
	}
}

chain_settlement :: proc(d: Descriptor, battle_id: [32]byte) -> Settlement {
	battle_id := battle_id
	out := eth_call(d, fmt.tprintf("%s%s", SEL_RESULT_OF, hex_str(battle_id[:])))
	return Settlement {
		status           = word_u8(out, 0),
		result           = word_u8(out, 1),
		final_seq        = word_u64(out, 2),
		state_commitment = word_hash32(out, 3),
	}
}

// ---- transport -------------------------------------------------------------

Rpc_Result :: struct {
	result: string,
}

eth_call :: proc(d: Descriptor, data: string) -> []byte {
	// Concatenated, not formatted: Odin's fmt reads `{` as a format construct.
	body := strings.concatenate(
		{
			`{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"`,
			d.contract,
			`","data":"`,
			data,
			`"},"latest"]}`,
		},
	)
	request := fmt.tprintf(
		"POST / HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		d.rpc_host,
		d.rpc_port,
		len(body),
		body,
	)

	addr := net.parse_address(d.rpc_host)
	if addr == nil {
		die("rpc host %q is not an address", d.rpc_host)
	}
	sock, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = addr, port = d.rpc_port})
	if derr != nil {
		die("rpc dial %s:%d: %v", d.rpc_host, d.rpc_port, derr)
	}
	defer net.close(sock)
	set_recv_timeout(sock)
	if err := send_all(sock, transmute([]byte)request); err != .None {
		die("rpc send to %s:%d: %v", d.rpc_host, d.rpc_port, err)
	}

	// The request asks for Connection: close, so the response ends at EOF and
	// no header parsing is needed to find its length.
	resp: [dynamic]byte
	chunk: [4096]byte
	for {
		n, rerr := net.recv_tcp(sock, chunk[:])
		if n > 0 {
			append(&resp, ..chunk[:n])
		}
		if n == 0 || rerr == .Connection_Closed {
			break
		}
		if rerr != .None {
			die("rpc receive from %s:%d: %v", d.rpc_host, d.rpc_port, rerr)
		}
	}

	text := string(resp[:])
	split := strings.index(text, "\r\n\r\n")
	if split < 0 {
		die("rpc response carries no body: %q", text)
	}
	payload: Rpc_Result
	json_body := text[split + 4:]
	if err := json.unmarshal_string(json_body, &payload); err != nil {
		die("rpc response is not JSON: %q", json_body)
	}
	raw := strings.trim_prefix(payload.result, "0x")
	if len(raw) == 0 || len(raw) % 64 != 0 {
		die("eth_call returned no usable result: %q", json_body)
	}
	out, ok := hex.decode(transmute([]byte)raw)
	if !ok {
		die("eth_call result is not hex: %q", payload.result)
	}
	return out
}

// ---- return words ----------------------------------------------------------
// 32 bytes each, big-endian, scalars right-aligned.

word :: proc(data: []byte, i: int) -> []byte {
	if (i + 1) * 32 > len(data) {
		die("eth_call returned %d bytes; word %d is missing", len(data), i)
	}
	return data[i * 32:(i + 1) * 32]
}

word_hash32 :: proc(data: []byte, i: int) -> [32]byte {
	out: [32]byte
	copy(out[:], word(data, i))
	return out
}

word_addr :: proc(data: []byte, i: int) -> [20]byte {
	out: [20]byte
	copy(out[:], word(data, i)[12:])
	return out
}

word_u8 :: proc(data: []byte, i: int) -> u8 {
	return word(data, i)[31]
}

word_u64 :: proc(data: []byte, i: int) -> u64 {
	v: u64
	for b in word(data, i)[24:] {
		v = v << 8 | u64(b)
	}
	return v
}

word_bool :: proc(data: []byte, i: int) -> bool {
	return word(data, i)[31] == 1
}

must_addr20 :: proc(s, what: string) -> [20]byte {
	out: [20]byte
	copy(out[:], must_hex(s, what, 20))
	return out
}
