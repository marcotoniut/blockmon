mod enc;
mod kernel;

use enc::{
    Dec, DecodeError, Hash32, decode_top, protocol_hash, put_bool, put_bytes, put_hash32,
    put_optional, put_seq, put_string, put_u8, put_u16, put_u32, put_u64,
};
use kernel::{
    BlockmonRecord, CaptureCommand, Context, ManifestV0, OUTCOME_CREATED, OUTCOME_REJECTED,
    PermitRecord, Supply, WorldV0, command_hash, encode_command, encode_effects, encode_manifest,
    encode_world, manifest_hash, transcript_hash, transition1, world_is_canonical, world_root,
};
use serde_json::Value;
use std::collections::HashMap;

// ---------- battle-channel transcript objects (canonical-encoding.md §4) ----------

struct Op {
    battle_id: Hash32,
    seq: u64,
    prev_hash: Hash32,
    author: u8,
    mv: String,
}

fn encode_op(op: &Op) -> Vec<u8> {
    let mut out = Vec::new();
    put_hash32(&mut out, &op.battle_id);
    put_u64(&mut out, op.seq);
    put_hash32(&mut out, &op.prev_hash);
    put_u8(&mut out, op.author);
    put_string(&mut out, &op.mv);
    out
}

fn op_hash(op: &Op) -> Hash32 {
    protocol_hash("blockmon/op/v0", &encode_op(op))
}

// ---------- helpers ----------

fn hx(v: &Value) -> Vec<u8> {
    let s = v.as_str().expect("hex string");
    hex::decode(s.strip_prefix("0x").expect("0x prefix")).expect("valid hex")
}

fn h32(v: &Value) -> Hash32 {
    hx(v).try_into().expect("32 bytes")
}

fn uint(v: &Value) -> u64 {
    v.as_str().expect("stringified int").parse().expect("u64")
}

fn enum_u8(v: &Value) -> u8 {
    u8::try_from(v.as_u64().expect("enum number")).expect("u8 enum")
}

fn to_hex(b: &[u8]) -> String {
    format!("0x{}", hex::encode(b))
}

struct Report {
    failures: Vec<String>,
}

impl Report {
    fn check(&mut self, name: &str, what: &str, got: &[u8], expected: &Value) {
        let exp = hx(expected);
        if got != exp.as_slice() {
            self.failures.push(format!(
                "{name}: {what} mismatch\n  got      {}\n  expected {}",
                to_hex(got),
                to_hex(&exp)
            ));
        }
    }
    fn fail(&mut self, msg: String) {
        self.failures.push(msg);
    }
}

// ---------- encoding of vector values by declared type ----------

// one linear dispatch over the vector value types; splitting it hides the flow
#[expect(clippy::too_many_lines)]
fn encode_value(ty: &str, value: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    match ty {
        "u8" => put_u8(&mut out, u8::try_from(uint(value)).expect("u8 range")),
        "u16" => put_u16(&mut out, u16::try_from(uint(value)).expect("u16 range")),
        "u32" => put_u32(&mut out, u32::try_from(uint(value)).expect("u32 range")),
        "u64" => put_u64(&mut out, uint(value)),
        "bool" => put_bool(&mut out, value.as_bool().expect("bool")),
        "bytes" => put_bytes(&mut out, &hx(value)),
        "string" => put_string(&mut out, value.as_str().expect("string")),
        "hash32" => put_hash32(&mut out, &h32(value)),
        "enum:author" | "enum:result" => put_u8(&mut out, enum_u8(value)),
        "optional:u64" => {
            let opt = if value.is_null() {
                None
            } else {
                Some(uint(value))
            };
            put_optional(&mut out, opt.as_ref(), |o, v| put_u64(o, *v));
        }
        "optional:bytes" => {
            let opt = if value.is_null() {
                None
            } else {
                Some(hx(value))
            };
            put_optional(&mut out, opt.as_ref(), |o, v| put_bytes(o, v));
        }
        "optional:string" => {
            let opt = if value.is_null() {
                None
            } else {
                Some(value.as_str().expect("string"))
            };
            put_optional(&mut out, opt.as_ref(), |o, v| put_string(o, v));
        }
        "optional:seq:u64" => {
            let opt: Option<Vec<u64>> = if value.is_null() {
                None
            } else {
                Some(value.as_array().expect("array").iter().map(uint).collect())
            };
            put_optional(&mut out, opt.as_ref(), |o, v| {
                put_seq(o, v, |o2, x| put_u64(o2, *x));
            });
        }
        "seq:u64" => {
            let items: Vec<u64> = value.as_array().expect("array").iter().map(uint).collect();
            put_seq(&mut out, &items, |o, v| put_u64(o, *v));
        }
        "seq:string" => {
            let items: Vec<&str> = value
                .as_array()
                .expect("array")
                .iter()
                .map(|s| s.as_str().expect("string"))
                .collect();
            put_seq(&mut out, &items, |o, v| put_string(o, v));
        }
        "seq:bytes" => {
            let items: Vec<Vec<u8>> = value.as_array().expect("array").iter().map(hx).collect();
            put_seq(&mut out, &items, |o, v| put_bytes(o, v));
        }
        "seq:seq:u64" => {
            let items: Vec<Vec<u64>> = value
                .as_array()
                .expect("array")
                .iter()
                .map(|a| a.as_array().expect("array").iter().map(uint).collect())
                .collect();
            put_seq(&mut out, &items, |o, v| {
                put_seq(o, v, |o2, x| put_u64(o2, *x));
            });
        }
        "seq:optional:u64" => {
            let items: Vec<Option<u64>> = value
                .as_array()
                .expect("array")
                .iter()
                .map(|v| if v.is_null() { None } else { Some(uint(v)) })
                .collect();
            put_seq(&mut out, &items, |o, v| {
                put_optional(o, v.as_ref(), |o2, x| put_u64(o2, *x));
            });
        }
        "record:string2" => {
            let a = value.as_array().expect("array of 2");
            put_string(&mut out, a[0].as_str().unwrap());
            put_string(&mut out, a[1].as_str().unwrap());
        }
        "record:op" => {
            let op = Op {
                battle_id: h32(&value["battle_id"]),
                seq: uint(&value["seq"]),
                prev_hash: h32(&value["prev_hash"]),
                author: enum_u8(&value["author"]),
                mv: value["move"].as_str().unwrap().to_string(),
            };
            out = encode_op(&op);
        }
        "record:checkpoint" => {
            put_hash32(&mut out, &h32(&value["battle_id"]));
            put_u64(&mut out, uint(&value["seq"]));
            put_hash32(&mut out, &h32(&value["transcript_head"]));
            put_u8(&mut out, enum_u8(&value["result"]));
        }
        "record:state" => {
            put_hash32(&mut out, &h32(&value["transcript_head"]));
            put_u8(&mut out, enum_u8(&value["result"]));
        }
        other => panic!("unknown vector type {other}"),
    }
    out
}

// ---------- strict decode of vector bytes by declared type ----------

// Dec's impl lifetime is early-bound, so the suggested `Dec::u8` fn items are
// not general enough for decode_top; the closures are required.
#[expect(clippy::redundant_closure_for_method_calls)]
fn decode_value(ty: &str, bytes: &[u8]) -> Result<(), DecodeError> {
    match ty {
        "u8" => decode_top(bytes, |d| d.u8()).map(|_| ()),
        "u16" => decode_top(bytes, |d| d.u16()).map(|_| ()),
        "u32" => decode_top(bytes, |d| d.u32()).map(|_| ()),
        "u64" => decode_top(bytes, |d| d.u64()).map(|_| ()),
        "bool" => decode_top(bytes, |d| d.bool()).map(|_| ()),
        "bytes" => decode_top(bytes, |d| d.bytes().map(<[u8]>::to_vec)).map(|_| ()),
        "string" => decode_top(bytes, |d| d.string().map(str::to_string)).map(|_| ()),
        "hash32" => decode_top(bytes, |d| d.hash32()).map(|_| ()),
        "enum:author" => decode_top(bytes, |d| d.enum_of(&[1, 2])).map(|_| ()),
        "enum:result" => decode_top(bytes, |d| d.enum_of(&[1, 2, 3])).map(|_| ()),
        "optional:u64" => decode_top(bytes, |d| d.optional(Dec::u64)).map(|_| ()),
        "optional:bytes" => {
            decode_top(bytes, |d| d.optional(|d| d.bytes().map(<[u8]>::to_vec))).map(|_| ())
        }
        "optional:string" => {
            decode_top(bytes, |d| d.optional(|d| d.string().map(str::to_string))).map(|_| ())
        }
        "optional:seq:u64" => decode_top(bytes, |d| d.optional(|d| d.seq(Dec::u64))).map(|_| ()),
        "seq:u64" => decode_top(bytes, |d| d.seq(Dec::u64)).map(|_| ()),
        "seq:string" => {
            decode_top(bytes, |d| d.seq(|d| d.string().map(str::to_string))).map(|_| ())
        }
        "seq:bytes" => decode_top(bytes, |d| d.seq(|d| d.bytes().map(<[u8]>::to_vec))).map(|_| ()),
        "seq:seq:u64" => decode_top(bytes, |d| d.seq(|d| d.seq(Dec::u64))).map(|_| ()),
        "seq:optional:u64" => decode_top(bytes, |d| d.seq(|d| d.optional(Dec::u64))).map(|_| ()),
        other => panic!("unknown decode type {other}"),
    }
}

// ---------- T1 vector parsing ----------

fn parse_world(v: &Value) -> WorldV0 {
    WorldV0 {
        subjects: v["subjects"].as_array().unwrap().iter().map(h32).collect(),
        blockmon: v["blockmon"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| BlockmonRecord {
                creature_id: h32(&b["creature_id"]),
                owner: h32(&b["owner"]),
                origin_permit: h32(&b["origin_permit"]),
            })
            .collect(),
        permits: v["permits"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| PermitRecord {
                permit_id: h32(&p["permit_id"]),
                subject: h32(&p["subject"]),
                encounter_class: enum_u8(&p["encounter_class"]),
                expiry_position: uint(&p["expiry_position"]),
                status: enum_u8(&p["status"]),
            })
            .collect(),
        supply: Supply {
            epoch: uint(&v["supply"]["epoch"]),
            envelope: uint(&v["supply"]["envelope"]),
            minted: uint(&v["supply"]["minted"]),
            consumed: uint(&v["supply"]["consumed"]),
            created: uint(&v["supply"]["created"]),
        },
    }
}

/// protocol.md §10 conservation identities, asserted on the computed transition
/// (not on vector data): rejections consume nothing; a roll consumes exactly one
/// capability and one permit; failed attempts never mint; supply accounting
/// stays within `created ≤ consumed ≤ minted ≤ envelope`; creature ids stay
/// unique (one owner per extant Blockmon).
fn assert_conservation(
    rep: &mut Report,
    name: &str,
    input: &WorldV0,
    in_enc: &[u8],
    next: &WorldV0,
    out_enc: &[u8],
    outcome: u8,
) {
    if outcome == OUTCOME_REJECTED {
        if out_enc != in_enc {
            rep.fail(format!(
                "{name}: conservation: rejection must leave state byte-identical"
            ));
        }
        return;
    }
    let (s, p) = (&next.supply, &input.supply);
    if s.consumed != p.consumed + 1
        || s.minted != p.minted
        || s.envelope != p.envelope
        || s.epoch != p.epoch
    {
        rep.fail(format!(
            "{name}: conservation: attempt must consume exactly one capability"
        ));
    }
    if s.created > s.consumed || s.consumed > s.minted || s.minted > s.envelope {
        rep.fail(format!(
            "{name}: conservation: created <= consumed <= minted <= envelope violated"
        ));
    }
    let (created_ok, blockmon_ok) = if outcome == OUTCOME_CREATED {
        (
            s.created == p.created + 1,
            next.blockmon.len() == input.blockmon.len() + 1,
        )
    } else {
        (
            s.created == p.created,
            next.blockmon.len() == input.blockmon.len(),
        )
    };
    if !created_ok || !blockmon_ok {
        rep.fail(format!(
            "{name}: conservation: creations != outcome (failed attempts waste; never mint)"
        ));
    }
    if !world_is_canonical(next) {
        rep.fail(format!(
            "{name}: conservation: output state not canonical (duplicate or unsorted keys)"
        ));
    }
}

fn check_transition(rep: &mut Report, name: &str, v: &Value) -> bool {
    let before = rep.failures.len();

    let manifest = ManifestV0 {
        round_period: uint(&v["manifest"]["round_period"]),
        entropy_safety_margin: uint(&v["manifest"]["entropy_safety_margin"]),
        catch_rate_bp: u32::try_from(uint(&v["manifest"]["catch_rate_bp"])).expect("u32 range"),
    };
    let m_enc = encode_manifest(&manifest);
    rep.check(name, "manifest_canonical", &m_enc, &v["manifest_canonical"]);
    rep.check(
        name,
        "manifest_hash",
        &manifest_hash(&manifest),
        &v["manifest_hash"],
    );

    let input = parse_world(&v["input_state"]);
    let in_enc = encode_world(&input);
    rep.check(name, "input_canonical", &in_enc, &v["input_canonical"]);
    let prev_root = world_root(&input);
    rep.check(name, "input_root", &prev_root, &v["input_root"]);

    let cmd = CaptureCommand {
        subject: h32(&v["command"]["subject"]),
        permit_id: h32(&v["command"]["permit_id"]),
    };
    rep.check(
        name,
        "command_canonical",
        &encode_command(&cmd),
        &v["command_canonical"],
    );
    let chash = command_hash(&cmd);
    rep.check(name, "command_hash", &chash, &v["command_hash"]);

    let ctx = Context {
        position: uint(&v["context"]["position"]),
        epoch: uint(&v["context"]["epoch"]),
        entropy_round: uint(&v["context"]["entropy_round"]),
        entropy_value: h32(&v["context"]["entropy_value"]),
    };

    let (next, effects, seed) = transition1(&input, &cmd, &ctx, &manifest);
    match (&seed.0, v["seed"].is_null()) {
        (Some(s), false) => rep.check(name, "seed", s, &v["seed"]),
        (None, true) => {}
        (Some(s), true) => rep.fail(format!(
            "{name}: computed seed {} but vector has none",
            to_hex(s)
        )),
        (None, false) => {
            rep.fail(format!("{name}: no seed computed but vector expects one"));
        }
    }
    let expected_effects = &v["effects"];
    if u64::from(effects.outcome) != expected_effects["outcome"].as_u64().unwrap() {
        rep.fail(format!("{name}: outcome {} != expected", effects.outcome));
    }
    match (
        &effects.reject_reason,
        expected_effects["reject_reason"].is_null(),
    ) {
        (Some(r), false) => {
            if u64::from(*r) != expected_effects["reject_reason"].as_u64().unwrap() {
                rep.fail(format!("{name}: reject_reason {r} != expected"));
            }
        }
        (None, true) => {}
        _ => rep.fail(format!("{name}: reject_reason presence mismatch")),
    }
    match (&effects.roll, expected_effects["roll"].is_null()) {
        (Some(r), false) => {
            if *r != uint(&expected_effects["roll"]) {
                rep.fail(format!("{name}: roll {r} != expected"));
            }
        }
        (None, true) => {}
        _ => rep.fail(format!("{name}: roll presence mismatch")),
    }
    let mut e_enc = Vec::new();
    encode_effects(&mut e_enc, &effects);
    rep.check(name, "effects_canonical", &e_enc, &v["effects_canonical"]);

    let out_enc = encode_world(&next);
    rep.check(name, "output_canonical", &out_enc, &v["output_canonical"]);
    let next_root = world_root(&next);
    rep.check(name, "output_root", &next_root, &v["output_root"]);

    let t_hash = transcript_hash(&chash, &prev_root, &next_root, &effects);
    rep.check(name, "transcript_hash", &t_hash, &v["transcript_hash"]);

    assert_conservation(rep, name, &input, &in_enc, &next, &out_enc, effects.outcome);

    rep.failures.len() == before
}

// ---------- per-file driver ----------

struct FileStats {
    checks_total: u32,
    checks_passed: u32,
    rejects_total: u32,
    rejects_ok: u32,
    t1_total: u32,
    t1_ok: u32,
    pairs_total: u32,
    pairs_ok: u32,
}

// one linear dispatch over the vector kinds; splitting it hides the flow
#[expect(clippy::too_many_lines)]
fn check_file(path: &str, rep: &mut Report) -> FileStats {
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).expect("read vectors"))
        .expect("parse vectors");

    // name -> distinct artifacts computed by THIS implementation
    let mut computed: HashMap<String, Vec<Vec<u8>>> = HashMap::new();

    let mut st = FileStats {
        checks_total: 0,
        checks_passed: 0,
        rejects_total: 0,
        rejects_ok: 0,
        t1_total: 0,
        t1_ok: 0,
        pairs_total: 0,
        pairs_ok: 0,
    };

    for v in doc["vectors"].as_array().expect("vectors array") {
        let name = v["name"].as_str().unwrap().to_string();
        let kind = v["kind"].as_str().unwrap();
        st.checks_total += 1;
        let before = rep.failures.len();
        match kind {
            "encode" => {
                let bytes = encode_value(v["type"].as_str().unwrap(), &v["value"]);
                rep.check(&name, "canonical", &bytes, &v["canonical"]);
                // round-trip: canonical bytes must decode cleanly
                let ty = v["type"].as_str().unwrap();
                if !ty.starts_with("record:")
                    && let Err(e) = decode_value(ty, &bytes)
                {
                    rep.fail(format!("{name}: canonical bytes failed to decode: {}", e.0));
                }
                let mut arts = vec![bytes.clone()];
                if let Some(domain) = v["domain"].as_str() {
                    let h = protocol_hash(domain, &bytes);
                    rep.check(&name, "hash", &h, &v["hash"]);
                    arts.push(h.to_vec());
                }
                computed.insert(name.clone(), arts);
            }
            "hash" => {
                let h = protocol_hash(v["domain"].as_str().unwrap(), &hx(&v["payload"]));
                rep.check(&name, "hash", &h, &v["hash"]);
                computed.insert(name.clone(), vec![h.to_vec()]);
            }
            "transcript" => {
                let battle_id = h32(&v["battle_id"]);
                let mut prev = [0u8; 32];
                let mut seq = 0u64;
                // seq is 1-based per the transcript spec; enumerate() would force a usize cast
                #[expect(clippy::explicit_counter_loop)]
                for o in v["ops"].as_array().unwrap() {
                    seq += 1;
                    let op = Op {
                        battle_id,
                        seq,
                        prev_hash: prev,
                        author: enum_u8(&o["author"]),
                        mv: o["move"].as_str().unwrap().to_string(),
                    };
                    prev = op_hash(&op);
                }
                rep.check(&name, "head", &prev, &v["head"]);
                computed.insert(name.clone(), vec![prev.to_vec()]);
            }
            "reject" => {
                st.rejects_total += 1;
                let ty = v["decode"].as_str().unwrap();
                match decode_value(ty, &hx(&v["bytes"])) {
                    Err(_) => st.rejects_ok += 1,
                    Ok(()) => rep.fail(format!("{name}: decoder ACCEPTED bytes it must reject")),
                }
            }
            "transition" => {
                st.t1_total += 1;
                if check_transition(rep, &name, v) {
                    st.t1_ok += 1;
                }
            }
            other => rep.fail(format!("{name}: unknown kind {other}")),
        }
        if rep.failures.len() == before {
            st.checks_passed += 1;
        }
    }

    let no_pairs = Vec::new();
    let pairs = doc["pairs_distinct"].as_array().unwrap_or(&no_pairs);
    for pair in pairs {
        st.checks_total += 1;
        st.pairs_total += 1;
        let a = pair[0].as_str().unwrap();
        let b = pair[1].as_str().unwrap();
        match (computed.get(a), computed.get(b)) {
            (Some(arts_a), Some(arts_b)) => {
                if arts_a.iter().zip(arts_b.iter()).all(|(x, y)| x != y) {
                    st.pairs_ok += 1;
                    st.checks_passed += 1;
                } else {
                    rep.fail(format!(
                        "distinctness pair ({a}, {b}): artifacts NOT distinct"
                    ));
                }
            }
            _ => rep.fail(format!(
                "distinctness pair ({a}, {b}): missing computed artifacts"
            )),
        }
    }
    st
}

// ---------- main ----------

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let paths = if args.is_empty() {
        vec!["../vectors/g0a-vectors.json".to_string()]
    } else {
        args
    };

    let mut rep = Report {
        failures: Vec::new(),
    };
    let (mut grand_total, mut grand_passed) = (0u32, 0u32);

    for path in &paths {
        let st = check_file(path, &mut rep);
        grand_total += st.checks_total;
        grand_passed += st.checks_passed;
        println!("{path}:");
        println!(
            "  checks passed:     {}/{}",
            st.checks_passed, st.checks_total
        );
        println!(
            "  rejection vectors: {}/{} rejected",
            st.rejects_ok, st.rejects_total
        );
        println!(
            "  transition (T1):   {}/{} independently reproduced",
            st.t1_ok, st.t1_total
        );
        println!("  distinct pairs:    {}/{}", st.pairs_ok, st.pairs_total);
    }

    if rep.failures.is_empty() {
        println!("RESULT: PASS ({grand_passed}/{grand_total} checks)");
    } else {
        println!(
            "RESULT: FAIL ({grand_passed}/{grand_total} checks, {} failure(s))",
            rep.failures.len()
        );
        for f in &rep.failures {
            println!("--- {f}");
        }
        std::process::exit(1);
    }
}
