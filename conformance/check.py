#!/usr/bin/env python3
"""Independent G0a conformance checker.

Re-derives every golden vector from docs/architecture/canonical-encoding.md
alone, in both corpora (constitutional seed and seeded expansion).
Deliberately shares no code with the Odin implementation: its purpose is to
catch "spec says X, Odin does Y, all Odin targets agree on Y". Transition
vectors are additionally held to the protocol.md §10 conservation identities;
byte agreement alone cannot pass.

Exit 0 iff every vector in every corpus verifies; prints one line per failure.
"""

import hashlib
import json
import struct
import sys

# --- canonical encoding, straight from the spec (§2) -------------------------


def enc_u8(v):
    assert 0 <= v <= 0xFF
    return struct.pack(">B", v)


def enc_u16(v):
    return struct.pack(">H", v)


def enc_u32(v):
    return struct.pack(">I", v)


def enc_u64(v):
    return struct.pack(">Q", v)


def enc_bool(v):
    return b"\x01" if v else b"\x00"


def enc_bytes(v):
    return enc_u32(len(v)) + v


def enc_string(v):
    return enc_bytes(v.encode("utf-8"))


def enc_hash32(v):
    assert len(v) == 32
    return v


def enc_enum(v):
    assert 1 <= v <= 0xFF
    return enc_u8(v)


def enc_optional(inner, v):
    return b"\x00" if v is None else b"\x01" + inner(v)


def enc_seq(inner, vs):
    return enc_u32(len(vs)) + b"".join(inner(v) for v in vs)


# --- protocol hash (§3) -------------------------------------------------------


def protocol_hash(domain: str, payload: bytes) -> bytes:
    d = domain.encode("ascii")
    assert 1 <= len(d) <= 255, "domain must be 1-255 bytes"
    return hashlib.sha256(bytes([len(d)]) + d + payload).digest()


# --- transcript objects (§4) ---------------------------------------------------


def enc_op(battle_id, seq, prev_hash, author, move):
    return (
        enc_hash32(battle_id)
        + enc_u64(seq)
        + enc_hash32(prev_hash)
        + enc_enum(author)
        + enc_string(move)
    )


def enc_checkpoint(battle_id, seq, head, result):
    return enc_hash32(battle_id) + enc_u64(seq) + enc_hash32(head) + enc_enum(result)


def enc_state(head, result):
    return enc_hash32(head) + enc_enum(result)


# --- Transition 1 objects (canonical-encoding.md §6) ----------------------------


def enc_world(w):
    out = enc_u32(len(w["subjects"])) + b"".join(unhex(s) for s in w["subjects"])
    out += enc_u32(len(w["blockmon"]))
    for r in w["blockmon"]:
        out += unhex(r["creature_id"]) + unhex(r["owner"]) + unhex(r["origin_permit"])
    out += enc_u32(len(w["permits"]))
    for p in w["permits"]:
        out += unhex(p["permit_id"]) + unhex(p["subject"]) + enc_enum(p["encounter_class"])
        out += enc_u64(int(p["expiry_position"])) + enc_enum(p["status"])
    s = w["supply"]
    for k in ("epoch", "envelope", "minted", "consumed", "created"):
        out += enc_u64(int(s[k]))
    return out


def enc_t1_manifest(m):
    return (
        enc_u64(int(m["round_period"]))
        + enc_u64(int(m["entropy_safety_margin"]))
        + enc_u32(int(m["catch_rate_bp"]))
    )


def t1_supply(state):
    s = state["supply"]
    return {k: int(s[k]) for k in ("epoch", "envelope", "minted", "consumed", "created")}


def t1_input_invalid(state, manifest):
    """INVALID_STATE per canonical-encoding.md §6, re-derived from the JSON:
    collections not strictly ascending, an unassigned enum discriminant, a
    supply violating created <= consumed <= minted <= envelope or a blockmon
    count differing from created (extant == created, protocol.md §10), or a
    manifest with round_period = 0."""
    for key, field in (("subjects", None), ("blockmon", "creature_id"), ("permits", "permit_id")):
        ids = [e if field is None else e[field] for e in state[key]]
        if any(not ids[i] < ids[i + 1] for i in range(len(ids) - 1)):
            return True
    if any(p["encounter_class"] != 1 or p["status"] not in (1, 2) for p in state["permits"]):
        return True
    s = t1_supply(state)
    if not s["created"] <= s["consumed"] <= s["minted"] <= s["envelope"]:
        return True
    if len(state["blockmon"]) != s["created"]:
        return True
    return int(manifest["round_period"]) == 0


def enc_t1_effects(fx):
    out = enc_enum(fx["outcome"])
    rejected = fx["outcome"] == 3
    out += enc_optional(enc_enum, fx["reject_reason"] if rejected else None)
    out += enc_optional(lambda v: enc_u64(int(v)), fx["roll"] if not rejected else None)
    out += enc_optional(unhex, fx["creature"])
    return out


# --- strict decoding for rejection vectors (§2) --------------------------------


class Reject(Exception):
    pass


class Reader:
    def __init__(self, data):
        self.data, self.off = data, 0

    def take(self, n):
        if self.off + n > len(self.data):
            raise Reject("truncated")
        out = self.data[self.off : self.off + n]
        self.off += n
        return out

    def finish(self):
        if self.off != len(self.data):
            raise Reject("trailing bytes")


def dec(kind, raw):
    r = Reader(raw)
    if kind == "bool":
        b = r.take(1)[0]
        if b > 1:
            raise Reject("bad bool")
    elif kind in ("u8", "u16", "u32", "u64"):
        r.take({"u8": 1, "u16": 2, "u32": 4, "u64": 8}[kind])
    elif kind == "string":
        n = struct.unpack(">I", r.take(4))[0]
        try:
            r.take(n).decode("utf-8")
        except UnicodeDecodeError:
            raise Reject("invalid utf-8") from None
    elif kind == "bytes":
        n = struct.unpack(">I", r.take(4))[0]
        r.take(n)
    elif kind == "hash32":
        r.take(32)
    elif kind == "enum:author":
        if r.take(1)[0] not in (1, 2):
            raise Reject("bad enum")
    elif kind == "enum:result":
        if r.take(1)[0] not in (1, 2, 3):
            raise Reject("bad enum")
    elif kind == "optional:u64":
        flag = r.take(1)[0]
        if flag > 1:
            raise Reject("bad optional flag")
        if flag == 1:
            r.take(8)
    elif kind == "optional:bytes":
        flag = r.take(1)[0]
        if flag > 1:
            raise Reject("bad optional flag")
        if flag == 1:
            n = struct.unpack(">I", r.take(4))[0]
            r.take(n)
    elif kind == "seq:u64":
        n = struct.unpack(">I", r.take(4))[0]
        for _ in range(n):
            r.take(8)
    else:
        raise SystemExit(f"unknown decode kind {kind!r}")
    r.finish()


# --- vector verification ---------------------------------------------------------


def unhex(s):
    assert s.startswith("0x")
    return bytes.fromhex(s[2:])


def encode_from_value(vtype, value):
    if vtype in ("u8", "u16", "u32", "u64"):
        return {"u8": enc_u8, "u16": enc_u16, "u32": enc_u32, "u64": enc_u64}[vtype](int(value))
    if vtype == "bool":
        return enc_bool(value)
    if vtype == "bytes":
        return enc_bytes(unhex(value))
    if vtype == "string":
        return enc_string(value)
    if vtype == "hash32":
        return enc_hash32(unhex(value))
    if vtype in ("enum:author", "enum:result"):
        return enc_enum(int(value))
    if vtype == "optional:u64":
        return enc_optional(lambda v: enc_u64(int(v)), value)
    if vtype == "optional:bytes":
        return enc_optional(lambda v: enc_bytes(unhex(v)), value)
    if vtype == "optional:string":
        return enc_optional(enc_string, value)
    if vtype == "optional:seq:u64":
        return enc_optional(lambda vs: enc_seq(lambda v: enc_u64(int(v)), vs), value)
    if vtype == "seq:u64":
        return enc_seq(lambda v: enc_u64(int(v)), value)
    if vtype == "seq:string":
        return enc_seq(enc_string, value)
    if vtype == "seq:bytes":
        return enc_seq(lambda v: enc_bytes(unhex(v)), value)
    if vtype == "seq:seq:u64":
        return enc_seq(lambda vs: enc_seq(lambda v: enc_u64(int(v)), vs), value)
    if vtype == "seq:optional:u64":
        return enc_seq(lambda v: enc_optional(lambda x: enc_u64(int(x)), v), value)
    if vtype == "record:string2":
        return enc_string(value[0]) + enc_string(value[1])
    if vtype == "record:op":
        return enc_op(
            unhex(value["battle_id"]),
            int(value["seq"]),
            unhex(value["prev_hash"]),
            value["author"],
            value["move"],
        )
    if vtype == "record:checkpoint":
        return enc_checkpoint(
            unhex(value["battle_id"]),
            int(value["seq"]),
            unhex(value["transcript_head"]),
            value["result"],
        )
    if vtype == "record:state":
        return enc_state(unhex(value["transcript_head"]), value["result"])
    raise SystemExit(f"unknown vector type {vtype!r}")


def check_file(path):
    with open(path) as f:
        doc = json.load(f)
    failures = 0
    hashes = {}

    def fail(name, msg):
        nonlocal failures
        failures += 1
        print(f"FAIL  {name}: {msg}")

    for v in doc["vectors"]:
        name, kind = v["name"], v["kind"]
        if kind == "encode":
            got = encode_from_value(v["type"], v["value"])
            if got != unhex(v["canonical"]):
                fail(
                    name, f"canonical bytes differ: derived {got.hex()} vs stated {v['canonical']}"
                )
                continue
            if "domain" in v:
                h = protocol_hash(v["domain"], got)
                hashes[name] = h
                if h != unhex(v["hash"]):
                    fail(name, "hash differs")
        elif kind == "hash":
            h = protocol_hash(v["domain"], unhex(v["payload"]))
            hashes[name] = h
            if h != unhex(v["hash"]):
                fail(name, "hash differs")
        elif kind == "transcript":
            battle_id = unhex(v["battle_id"])
            prev = bytes(32)  # genesis
            for i, op in enumerate(v["ops"], start=1):
                prev = protocol_hash(
                    "blockmon/op/v0", enc_op(battle_id, i, prev, op["author"], op["move"])
                )
            hashes[name] = prev
            if prev != unhex(v["head"]):
                fail(name, f"transcript head differs: derived {prev.hex()}")
        elif kind == "transition":
            # Independent re-derivation of every encoding/hash boundary. The
            # kernel's semantic step (input -> output) is deliberately NOT
            # recomputed here: that is G0c's independent implementation.
            checks = []
            mb = enc_t1_manifest(v["manifest"])
            checks.append(("manifest_canonical", mb == unhex(v["manifest_canonical"])))
            mh = protocol_hash("blockmon/manifest/v0", mb)
            checks.append(("manifest_hash", mh == unhex(v["manifest_hash"])))
            ib = enc_world(v["input_state"])
            checks.append(("input_canonical", ib == unhex(v["input_canonical"])))
            checks.append(
                ("input_root", protocol_hash("blockmon/world/v0", ib) == unhex(v["input_root"]))
            )
            ob = enc_world(v["output_state"])
            checks.append(("output_canonical", ob == unhex(v["output_canonical"])))
            out_root = protocol_hash("blockmon/world/v0", ob)
            checks.append(("output_root", out_root == unhex(v["output_root"])))
            cb = unhex(v["command"]["subject"]) + unhex(v["command"]["permit_id"])
            checks.append(("command_canonical", cb == unhex(v["command_canonical"])))
            cmd_h = protocol_hash("blockmon/capture-cmd/v0", cb)
            checks.append(("command_hash", cmd_h == unhex(v["command_hash"])))
            ctx = v["context"]
            m = v["manifest"]
            fx = v["effects"]
            # INVALID_STATE is the first precondition: reason 9 iff the input
            # world or manifest fails the spec's validity predicate, and every
            # other outcome implies the input was valid
            invalid_input = t1_input_invalid(v["input_state"], m)
            if fx["outcome"] == 3 and fx["reject_reason"] == 9:
                checks.append(("invalid_state_derived", invalid_input))
            else:
                checks.append(("input_validity_derived", not invalid_input))
            # entropy assignment: the kernel checks the rule before every check
            # except epoch and state validity, so an executed attempt or any
            # later rejection reason implies equality; reason 7 implies inequality
            if int(m["round_period"]) > 0:
                assigned = (
                    int(ctx["position"]) // int(m["round_period"])
                    + 1
                    + int(m["entropy_safety_margin"])
                )
                if fx["outcome"] != 3 or fx["reject_reason"] in (1, 2, 3, 4, 5, 6):
                    checks.append(
                        ("entropy_assignment_rule", int(ctx["entropy_round"]) == assigned)
                    )
                elif fx["reject_reason"] == 7:
                    checks.append(
                        ("entropy_mismatch_rejected", int(ctx["entropy_round"]) != assigned)
                    )
            if v["seed"] is not None:
                seed = protocol_hash(
                    "blockmon/capture-roll/v0",
                    unhex(ctx["entropy_value"]) + unhex(v["command"]["permit_id"]) + mh,
                )
                checks.append(("seed", seed == unhex(v["seed"])))
                checks.append(("roll", int.from_bytes(seed[:8], "big") % 10000 == int(fx["roll"])))
            if fx["creature"] is not None:
                cid = protocol_hash("blockmon/creature-id/v0", unhex(v["command"]["permit_id"]))
                checks.append(("creature_id", cid == unhex(fx["creature"])))
            fxb = enc_t1_effects(fx)
            checks.append(("effects_canonical", fxb == unhex(v["effects_canonical"])))
            tr = protocol_hash(
                "blockmon/transition/v0", cmd_h + unhex(v["input_root"]) + out_root + fxb
            )
            checks.append(("transcript_hash", tr == unhex(v["transcript_hash"])))
            # protocol.md §10, the identities Transition 1 can express,
            # re-derived from the stated states alone: cross-platform byte
            # agreement cannot pass without them
            si, so = t1_supply(v["input_state"]), t1_supply(v["output_state"])
            checks.append(
                (
                    "conserve_envelope_minted",
                    so["envelope"] == si["envelope"] and so["minted"] == si["minted"],
                )
            )
            pid = v["command"]["permit_id"]
            if fx["outcome"] == 3:
                checks.append(
                    ("reject_purity", v["output_canonical"] == v["input_canonical"] and so == si)
                )
                checks.append(("reject_reason_present", fx["reject_reason"] is not None))
            else:
                checks.append(("consume_on_attempt", so["consumed"] == si["consumed"] + 1))
                created_delta = 1 if fx["outcome"] == 1 else 0
                checks.append(
                    (
                        "creations_le_consumed",
                        so["created"] == si["created"] + created_delta
                        and so["created"] <= so["consumed"],
                    )
                )
                checks.append(("supply_order", so["consumed"] <= so["minted"] <= so["envelope"]))
                checks.append(
                    ("extant_equals_created", len(v["output_state"]["blockmon"]) == so["created"])
                )
                pout = [p for p in v["output_state"]["permits"] if p["permit_id"] == pid]
                checks.append(("permit_consumed", len(pout) == 1 and pout[0]["status"] == 2))
                pin = [p for p in v["input_state"]["permits"] if p["permit_id"] == pid]
                checks.append(
                    (
                        "attempt_preconditions",
                        len(pin) == 1
                        and pin[0]["status"] == 1
                        and pin[0]["subject"] == v["command"]["subject"]
                        and int(ctx["position"]) < int(pin[0]["expiry_position"])
                        and int(ctx["epoch"]) == si["epoch"],
                    )
                )
                checks.append(
                    (
                        "outcome_matches_roll",
                        (fx["outcome"] == 1) == (int(fx["roll"]) < int(m["catch_rate_bp"])),
                    )
                )
                for key, field in (
                    ("subjects", None),
                    ("blockmon", "creature_id"),
                    ("permits", "permit_id"),
                ):
                    ids = [e if field is None else e[field] for e in v["output_state"][key]]
                    checks.append(
                        (
                            f"canonical_order_{key}",
                            all(ids[i] < ids[i + 1] for i in range(len(ids) - 1)),
                        )
                    )
                if fx["outcome"] == 1:
                    mine = [
                        b
                        for b in v["output_state"]["blockmon"]
                        if b["creature_id"] == fx["creature"]
                    ]
                    checks.append(
                        (
                            "created_ownership",
                            len(mine) == 1
                            and mine[0]["owner"] == v["command"]["subject"]
                            and mine[0]["origin_permit"] == pid,
                        )
                    )
            for label, ok in checks:
                if not ok:
                    fail(name, f"{label} differs")
        elif kind == "reject":
            try:
                dec(v["decode"], unhex(v["bytes"]))
                fail(name, "malformed input was accepted")
            except Reject:
                pass
        else:
            fail(name, f"unknown kind {kind!r}")

    for a, b in doc.get("pairs_distinct", []):
        if a in hashes and b in hashes:
            if hashes[a] == hashes[b]:
                fail(f"{a}/{b}", "pair hashes collide; encoding is ambiguous")
        else:
            fail(f"{a}/{b}", "pair member missing a derivable hash")

    total = len(doc["vectors"]) + len(doc.get("pairs_distinct", []))
    tier = doc.get("tier", "seed")
    status = "FAIL" if failures else "OK"
    print(
        f"{status}  {tier} {path}: {total - failures}/{total} checks passed "
        f"(independent derivation)"
    )
    return failures


def main():
    paths = sys.argv[1:] or [
        "conformance/vectors/g0a-vectors.json",
        "conformance/vectors/g0a-expansion.json",
    ]
    return 1 if sum(check_file(p) for p in paths) else 0


if __name__ == "__main__":
    sys.exit(main())
