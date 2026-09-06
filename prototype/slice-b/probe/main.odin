// Slice B protocol probe (prototype-and-technology.md §2.2). Not a game client.
//
// Simulates both battle participants in one process: derives ephemeral battle
// material, establishes the battle session secret from both sides, runs a
// deterministic representative exchange as a hash-chained Ed25519-signed
// transcript, and emits everything the E2E harness needs as JSON on stdout.
//
// All chain cryptography (secp256k1, Keccak-256) is deliberately absent here;
// the harness delegates it to Foundry's cast (architecture.md §21).
//
// Determinism: key material comes from hard-coded test seeds, and the battle
// "entropy" is a fixed test seed (battle-channel.md §7, register Q15).
// Protocol bytes and hashes follow docs/architecture/canonical-encoding.md
// via protocol/canonical; nothing protocol-visible is hand-rolled here.
package probe

import canonical "../../../protocol/canonical"
import ch "../channel"

import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"

BATTLE_ID_STR :: "blockmon/test-battle/1"
RULESET_STR :: "blockmon/ruleset/v0-test"

// Hard-coded deterministic test seeds. Real clients generate these fresh per
// battle; the slice pins them so every run yields identical vectors for G0a.
SEED_ED_A := [32]byte{
	0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
	0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
	0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
	0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
}
SEED_ED_B := [32]byte{
	0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
	0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
	0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
	0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
}
SEED_X_A := [32]byte{
	0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
	0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50,
	0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
	0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60,
}
SEED_X_B := [32]byte{
	0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
	0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70,
	0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
	0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f, 0x80,
}

sha256_bytes :: proc(chunks: ..[]byte) -> [32]byte {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	for c in chunks {
		sha2.update(&ctx, c)
	}
	out: [32]byte
	sha2.final(&ctx, out[:])
	return out
}

hex_str :: proc(b: []byte) -> string {
	s, _ := hex.encode(b)
	return string(s)
}

Op :: struct {
	seq:       u64,
	author:    string, // "A" | "B" (display; canonical bytes carry the enum)
	move:      string,
	prev_hash: [32]byte,
	op_hash:   [32]byte,
	sig:       [ed25519.SIGNATURE_SIZE]byte,
}

main :: proc() {
	battle_id := sha256_bytes(transmute([]byte)string(BATTLE_ID_STR))
	ruleset := sha256_bytes(transmute([]byte)string(RULESET_STR))

	// --- ephemeral battle identities (per battle, per player) ---
	ed_a, ed_b: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&ed_a, SEED_ED_A[:]) ||
	   !ed25519.private_key_set_bytes(&ed_b, SEED_ED_B[:]) {
		fmt.eprintln("ed25519 seed rejected")
		os.exit(1)
	}
	ed_pk_a, ed_pk_b: [32]byte
	ed25519.private_key_public_bytes(&ed_a, ed_pk_a[:])
	ed25519.private_key_public_bytes(&ed_b, ed_pk_b[:])

	x_pk_a := ch.x_public(SEED_X_A)
	x_pk_b := ch.x_public(SEED_X_B)

	// --- session secret: both sides derive independently, must agree ---
	sess_a := ch.derive_session(battle_id, SEED_X_A, x_pk_b)
	sess_b := ch.derive_session(battle_id, SEED_X_B, x_pk_a)
	if sess_a.k_battle != sess_b.k_battle {
		fmt.eprintln("session secret derivations disagree")
		os.exit(1)
	}
	k_battle, k_transport, k_hidden := sess_a.k_battle, sess_a.transport, sess_a.hidden

	// --- representative exchange: two moves, hash-chained, cross-verified ---
	moves := [2]struct {
		author: string,
		move:   string,
	}{{"A", ch.MOVE_A}, {"B", ch.MOVE_B}}

	ops: [2]Op
	prev: [32]byte // genesis prev = 0x00..00 (canonical-encoding.md §4)
	for m, i in moves {
		seq := u64(i + 1)
		author := canonical.AUTHOR_A if m.author == "A" else canonical.AUTHOR_B
		cop := canonical.Op{battle_id, seq, prev, author, m.move}
		bytes := canonical.encode_op(cop)
		h := canonical.op_hash(cop)
		signer := &ed_a if m.author == "A" else &ed_b
		s: [ed25519.SIGNATURE_SIZE]byte
		ed25519.sign(signer, bytes[:], s[:])
		ops[i] = Op{seq, m.author, m.move, prev, h, s}
		prev = h

		// counterparty verification: each side checks the other's signature
		verify_pk: ed25519.Public_Key
		pk_bytes := ed_pk_a if m.author == "A" else ed_pk_b
		if !ed25519.public_key_set_bytes(&verify_pk, pk_bytes[:]) ||
		   !ed25519.verify(&verify_pk, bytes[:], s[:]) {
			fmt.eprintln("counterparty op verification failed at seq", seq)
			os.exit(1)
		}
	}
	transcript_head := ops[1].op_hash

	result := ch.resolve_result(ops[0].move, ops[1].move)
	final_seq: u64 = u64(len(ops))

	commitment := canonical.state_commitment(transcript_head, result)

	// final checkpoint, dual-signed with the ephemeral keys (channel evidence;
	// the harness adds wallet co-signatures for the EVM stand-in)
	ck := canonical.encode_checkpoint(canonical.Checkpoint{battle_id, final_seq, transcript_head, result})
	ck_sig_a, ck_sig_b: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&ed_a, ck[:], ck_sig_a[:])
	ed25519.sign(&ed_b, ck[:], ck_sig_b[:])

	// --- emit ---
	fmt.printf("{{\n")
	fmt.printf("  \"battle_id\": \"0x%s\",\n", hex_str(battle_id[:]))
	fmt.printf("  \"ruleset_hash\": \"0x%s\",\n", hex_str(ruleset[:]))
	fmt.printf("  \"ed_pk_a\": \"0x%s\",\n", hex_str(ed_pk_a[:]))
	fmt.printf("  \"ed_pk_b\": \"0x%s\",\n", hex_str(ed_pk_b[:]))
	fmt.printf("  \"x_pk_a\": \"0x%s\",\n", hex_str(x_pk_a[:]))
	fmt.printf("  \"x_pk_b\": \"0x%s\",\n", hex_str(x_pk_b[:]))
	fmt.printf("  \"k_battle\": \"0x%s\",\n", hex_str(k_battle[:]))
	fmt.printf("  \"k_transport\": \"0x%s\",\n", hex_str(k_transport[:]))
	fmt.printf("  \"k_hidden\": \"0x%s\",\n", hex_str(k_hidden[:]))
	fmt.printf("  \"ops\": [\n")
	for &op, i in ops {
		comma := "," if i + 1 < len(ops) else ""
		fmt.printf(
			"    {{\"seq\": %d, \"author\": \"%s\", \"move\": \"%s\", \"op_hash\": \"0x%s\", \"sig\": \"0x%s\"}}%s\n",
			op.seq, op.author, op.move, hex_str(op.op_hash[:]), hex_str(op.sig[:]), comma,
		)
	}
	fmt.printf("  ],\n")
	fmt.printf("  \"transcript_head\": \"0x%s\",\n", hex_str(transcript_head[:]))
	fmt.printf("  \"final_seq\": %d,\n", final_seq)
	fmt.printf("  \"result\": %d,\n", result)
	fmt.printf("  \"state_commitment\": \"0x%s\",\n", hex_str(commitment[:]))
	fmt.printf("  \"ck_sig_ed_a\": \"0x%s\",\n", hex_str(ck_sig_a[:]))
	fmt.printf("  \"ck_sig_ed_b\": \"0x%s\"\n", hex_str(ck_sig_b[:]))
	fmt.printf("}}\n")
}
