//! Reads corpus inputs, recomputes every recorded output and compares.

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use crate::encoding::{Hash32, hex32};
use crate::invariants::{self, changed_keys, key_label};
use crate::kernel::{self, Transition};
use crate::smt::{DOMAIN_WORLD_V1, WorldCommitmentV1};
use crate::t1::{
    BlockmonRecord, CaptureCommand, ContextV0, EffectsV0, ManifestV0, Outcome, PermitRecord,
    Supply, TranscriptV0, WorldV0,
};
use crate::world::{self, ReadError, WorldStore};

pub struct Finding {
    pub case: String,
    pub field: String,
    pub computed: String,
    pub recorded: String,
}

#[derive(Default)]
pub struct Tally {
    pub kind: &'static str,
    pub checks: usize,
    pub compared: usize,
    pub mismatches: Vec<Finding>,
    pub info_compared: usize,
    pub info_mismatches: Vec<Finding>,
    pub invariant_failures: Vec<(String, String)>,
    pub errors: Vec<(String, String)>,
    pub not_compared: BTreeSet<String>,
    pub max_reads: usize,
    pub max_writes: usize,
    /// Computed transitions by `Outcome` discriminant; slot 0 unused.
    pub outcomes: [usize; 4],
    /// Cases whose listing the §6 state reader refused, so no transition ran.
    pub refused: usize,
}

impl Tally {
    pub const fn passed(&self) -> bool {
        self.mismatches.is_empty() && self.invariant_failures.is_empty() && self.errors.is_empty()
    }

    fn finding(
        case: &str,
        field: &str,
        computed: &Value,
        recorded: Option<&Value>,
    ) -> Option<Finding> {
        let recorded_text = recorded.map_or_else(|| "<absent>".to_owned(), Value::to_string);
        (recorded != Some(computed)).then(|| Finding {
            case: case.to_owned(),
            field: field.to_owned(),
            computed: computed.to_string(),
            recorded: recorded_text,
        })
    }

    fn cmp(&mut self, case: &str, field: &str, computed: &Value, recorded: Option<&Value>) {
        self.compared += 1;
        self.mismatches
            .extend(Self::finding(case, field, computed, recorded));
    }

    fn info(&mut self, case: &str, field: &str, computed: &Value, recorded: Option<&Value>) {
        self.info_compared += 1;
        self.info_mismatches
            .extend(Self::finding(case, field, computed, recorded));
    }
}

/// `parent.k`, reporting a recorded `null` parent as `null` rather than as an absent field.
fn member<'a>(parent: Option<&'a Value>, k: &str) -> Option<&'a Value> {
    parent.and_then(|p| if p.is_null() { Some(p) } else { p.get(k) })
}

fn get<'a>(v: &'a Value, k: &str) -> Result<&'a Value, String> {
    v.get(k).ok_or_else(|| format!("missing field {k}"))
}

fn hash(v: &Value) -> Result<Hash32, String> {
    let s = v
        .as_str()
        .ok_or_else(|| format!("expected hex string, got {v}"))?;
    let h = s
        .strip_prefix("0x")
        .ok_or_else(|| format!("hex without 0x: {s}"))?;
    let b = hex::decode(h).map_err(|e| format!("bad hex {s}: {e}"))?;
    b.try_into().map_err(|_| format!("not 32 bytes: {s}"))
}

fn dec_u64(v: &Value) -> Result<u64, String> {
    let s = v
        .as_str()
        .ok_or_else(|| format!("expected decimal string, got {v}"))?;
    s.parse().map_err(|e| format!("bad u64 {s}: {e}"))
}

fn dec_u32(v: &Value) -> Result<u32, String> {
    let s = v
        .as_str()
        .ok_or_else(|| format!("expected decimal string, got {v}"))?;
    s.parse().map_err(|e| format!("bad u32 {s}: {e}"))
}

fn int_u8(v: &Value) -> Result<u8, String> {
    v.as_u64()
        .and_then(|n| u8::try_from(n).ok())
        .ok_or_else(|| format!("expected u8 integer, got {v}"))
}

fn array<'a>(v: &'a Value, k: &str) -> Result<&'a Vec<Value>, String> {
    get(v, k)?
        .as_array()
        .ok_or_else(|| format!("{k} is not an array"))
}

/// Why a case produced no transition.
#[derive(Debug)]
enum Unrun {
    /// The JSON does not describe kernel input.
    Input(String),
    /// The §6 state reader refused the listing: there is no outcome, commitment or transcript.
    /// The manifest and command hashes do not depend on the state, so they are still defined.
    Refused {
        why: String,
        manifest_hash: Hash32,
        command_hash: Hash32,
    },
}

impl From<String> for Unrun {
    fn from(e: String) -> Self {
        Self::Input(e)
    }
}

/// The JSON listing as given; nothing is sorted, merged or validated.
fn parse_listing(v: &Value) -> Result<WorldV0, String> {
    let subjects = array(v, "subjects")?
        .iter()
        .map(hash)
        .collect::<Result<_, _>>()?;
    let blockmon = array(v, "blockmon")?
        .iter()
        .map(|b| {
            Ok(BlockmonRecord {
                creature_id: hash(get(b, "creature_id")?)?,
                owner: hash(get(b, "owner")?)?,
                origin_permit: hash(get(b, "origin_permit")?)?,
            })
        })
        .collect::<Result<_, String>>()?;
    let permits = array(v, "permits")?
        .iter()
        .map(|p| {
            Ok(PermitRecord {
                permit_id: hash(get(p, "permit_id")?)?,
                subject: hash(get(p, "subject")?)?,
                encounter_class: int_u8(get(p, "encounter_class")?)?,
                expiry_position: dec_u64(get(p, "expiry_position")?)?,
                status: int_u8(get(p, "status")?)?,
            })
        })
        .collect::<Result<_, String>>()?;
    let s = get(v, "supply")?;
    let supply = Supply {
        epoch: dec_u64(get(s, "epoch")?)?,
        envelope: dec_u64(get(s, "envelope")?)?,
        minted: dec_u64(get(s, "minted")?)?,
        consumed: dec_u64(get(s, "consumed")?)?,
        created: dec_u64(get(s, "created")?)?,
    };
    Ok(WorldV0 {
        subjects,
        blockmon,
        permits,
        supply,
    })
}

fn refusal(e: &ReadError) -> String {
    match e {
        ReadError::NoMapping(k) => format!(
            "refused by the state reader: {} key {} has two different records, which denote no \
             mapping",
            k.tag.name(),
            hex32(&k.key)
        ),
        ReadError::Structure(e) => format!("refused by the state reader: not a listing ({e:?})"),
    }
}

fn parse_manifest(v: &Value) -> Result<ManifestV0, String> {
    Ok(ManifestV0 {
        round_period: dec_u64(get(v, "round_period")?)?,
        entropy_safety_margin: dec_u64(get(v, "entropy_safety_margin")?)?,
        catch_rate_bp: dec_u32(get(v, "catch_rate_bp")?)?,
    })
}

fn parse_command(v: &Value) -> Result<CaptureCommand, String> {
    Ok(CaptureCommand {
        subject: hash(get(v, "subject")?)?,
        permit_id: hash(get(v, "permit_id")?)?,
    })
}

fn parse_context(v: &Value) -> Result<ContextV0, String> {
    Ok(ContextV0 {
        position: dec_u64(get(v, "position")?)?,
        epoch: dec_u64(get(v, "epoch")?)?,
        entropy_round: dec_u64(get(v, "entropy_round")?)?,
        entropy_value: hash(get(v, "entropy_value")?)?,
    })
}

fn jh(h: &Hash32) -> Value {
    Value::String(hex32(h))
}

fn jd(n: u64) -> Value {
    Value::String(n.to_string())
}

fn world_json(w: &WorldV0) -> Value {
    json!({
        "subjects": w.subjects.iter().map(jh).collect::<Vec<_>>(),
        "blockmon": w.blockmon.iter().map(|b| json!({
            "creature_id": jh(&b.creature_id), "owner": jh(&b.owner), "origin_permit": jh(&b.origin_permit),
        })).collect::<Vec<_>>(),
        "permits": w.permits.iter().map(|p| json!({
            "permit_id": jh(&p.permit_id), "subject": jh(&p.subject),
            "encounter_class": p.encounter_class, "expiry_position": jd(p.expiry_position), "status": p.status,
        })).collect::<Vec<_>>(),
        "supply": {
            "epoch": jd(w.supply.epoch), "envelope": jd(w.supply.envelope), "minted": jd(w.supply.minted),
            "consumed": jd(w.supply.consumed), "created": jd(w.supply.created),
        },
    })
}

fn effects_json(e: &EffectsV0) -> Value {
    json!({
        "outcome": e.outcome as u8,
        "reject_reason": e.reject_reason.map(|r| r as u8),
        "roll": e.roll.map(jd),
        "creature": e.creature.as_ref().map(jh),
    })
}

/// The commitment fields as named in the corpora; `None` where §7 gives no root.
fn commitment_json(c: Option<&WorldCommitmentV1>) -> Map<String, Value> {
    let undefined = || Value::String("<undefined: a refused update>".into());
    let f = |g: fn(&WorldCommitmentV1) -> Value| c.map_or_else(undefined, g);
    let mut m = Map::new();
    m.insert("subject_root".into(), f(|c| jh(&c.subject_root)));
    m.insert("blockmon_root".into(), f(|c| jh(&c.blockmon_root)));
    m.insert("encounter_root".into(), f(|c| jh(&c.encounter_root)));
    m.insert("supply_root".into(), f(|c| jh(&c.supply_root)));
    m.insert(
        "world_commitment_bytes".into(),
        f(|c| Value::String(format!("0x{}", hex::encode(c.encode())))),
    );
    m.insert("world_root".into(), f(|c| jh(&c.world_root())));
    m.insert(
        "supply_commitment".into(),
        f(|c| jh(&c.supply_commitment())),
    );
    m
}

const ROOT_FIELDS: [&str; 5] = [
    "subject_root",
    "blockmon_root",
    "encounter_root",
    "supply_root",
    "world_root",
];
const STATE_PARTS: [&str; 3] = ["subjects", "blockmon", "permits"];
const SUPPLY_FIELDS: [&str; 5] = ["epoch", "envelope", "minted", "consumed", "created"];
const EFFECT_FIELDS: [&str; 4] = ["outcome", "reject_reason", "roll", "creature"];

struct Computed {
    t: Transition,
    pre: Option<WorldCommitmentV1>,
    post: Option<WorldCommitmentV1>,
    command_hash: Hash32,
    manifest_hash: Hash32,
}

fn compute(case: &Value, tally: &mut Tally, name: &str) -> Result<(WorldV0, Computed), Unrun> {
    let manifest = parse_manifest(get(case, "manifest")?)?;
    let cmd = parse_command(get(case, "command")?)?;
    let ctx = parse_context(get(case, "context")?)?;
    let listed = parse_listing(get(case, "input_state")?)?;
    let world = world::read_state(&listed.encode()).map_err(|e| Unrun::Refused {
        why: refusal(&e),
        manifest_hash: manifest.hash(),
        command_hash: cmd.hash(),
    })?;
    let mut store = WorldStore::genesis(&world).map_err(|e| format!("no commitment: {e:?}"))?;
    let t = kernel::transition(&world, &cmd, &ctx, &manifest);
    for v in invariants::check(&world, &cmd, &ctx, &manifest, &t) {
        tally.invariant_failures.push((name.to_owned(), v));
    }
    tally.outcomes[t.effects.outcome as usize] += 1;
    tally.max_reads = tally.max_reads.max(t.reads.len());
    tally.max_writes = tally.max_writes.max(t.writes.len());
    let pre = Some(store.commitment());
    let post = if t.effects.outcome == Outcome::Rejected {
        pre
    } else {
        store.advance(&t.writes).ok()
    };
    let c = Computed {
        pre,
        post,
        command_hash: cmd.hash(),
        manifest_hash: manifest.hash(),
        t,
    };
    Ok((world, c))
}

fn compare_effects_and_state(tally: &mut Tally, name: &str, case: &Value, c: &Computed) {
    let eff = effects_json(&c.t.effects);
    let rec_eff = case.get("effects");
    for f in EFFECT_FIELDS {
        tally.cmp(
            name,
            &format!("effects.{f}"),
            &eff[f],
            rec_eff.and_then(|e| e.get(f)),
        );
    }
    let out = world_json(&c.t.next);
    let rec_out = case.get("output_state");
    for f in STATE_PARTS {
        tally.cmp(
            name,
            &format!("output_state.{f}"),
            &out[f],
            rec_out.and_then(|o| o.get(f)),
        );
    }
    let rec_supply = rec_out.and_then(|o| o.get("supply"));
    for f in SUPPLY_FIELDS {
        tally.cmp(
            name,
            &format!("output_state.supply.{f}"),
            &out["supply"][f],
            rec_supply.and_then(|s| s.get(f)),
        );
    }
}

fn note_unhandled(tally: &mut Tally, obj: &Value, handled: &[&str], prefix: &str) {
    if let Some(m) = obj.as_object() {
        for k in m.keys().filter(|k| !handled.contains(&k.as_str())) {
            tally.not_compared.insert(format!("{prefix}{k}"));
        }
    }
}

fn label_set(labels: impl IntoIterator<Item = String>) -> Value {
    let set: BTreeSet<String> = labels.into_iter().collect();
    Value::Array(set.into_iter().map(Value::String).collect())
}

fn recorded_set(v: Option<&Value>) -> Option<Value> {
    let arr = v?.as_array()?;
    let set: BTreeSet<String> = arr
        .iter()
        .filter_map(|x| x.as_str().map(str::to_owned))
        .collect();
    (set.len() == arr.len()).then(|| Value::Array(set.into_iter().map(Value::String).collect()))
}

/// §6: a refused listing has no outcome, commitment or transcript, so each output the case
/// records agrees only if it is absent or `null`.
fn compare_refusal(tally: &mut Tally, name: &str, case: &Value, why: &str, outputs: &[&str]) {
    tally.refused += 1;
    let none = Value::String(format!("<none: {why}>"));
    for f in outputs {
        let recorded = case.get(*f).unwrap_or(&Value::Null);
        let computed = if recorded.is_null() {
            &Value::Null
        } else {
            &none
        };
        tally.cmp(name, f, computed, Some(recorded));
    }
}

const HAND_OUTPUTS: [&str; 5] = ["outcome", "effects", "output_state", "input", "output"];

const HAND_HANDLED: [&str; 14] = [
    "name",
    "outcome",
    "rejected",
    "writes",
    "keys_written",
    "roots_unchanged",
    "command",
    "context",
    "manifest",
    "effects",
    "input_state",
    "output_state",
    "input",
    "output",
];

pub fn check_hand_tier(doc: &Value) -> Tally {
    let mut tally = Tally {
        kind: "hand-derived checks",
        ..Tally::default()
    };
    tally.cmp(
        "<file>",
        "commitment_version",
        &Value::String(DOMAIN_WORLD_V1.into()),
        doc.get("commitment_version"),
    );
    note_unhandled(&mut tally, doc, &["checks", "commitment_version"], "");
    let checks = doc
        .get("checks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for case in &checks {
        tally.checks += 1;
        let name = case
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("<unnamed>")
            .to_owned();
        note_unhandled(&mut tally, case, &HAND_HANDLED, "checks[].");
        let (world, c) = match compute(case, &mut tally, &name) {
            Ok(x) => x,
            Err(Unrun::Input(e)) => {
                tally.errors.push((name, e));
                continue;
            }
            Err(Unrun::Refused { why, .. }) => {
                compare_refusal(&mut tally, &name, case, &why, &HAND_OUTPUTS);
                continue;
            }
        };
        tally.cmp(
            &name,
            "outcome",
            &json!(c.t.effects.outcome as u8),
            case.get("outcome"),
        );
        compare_effects_and_state(&mut tally, &name, case, &c);
        for (side, comm) in [("input", c.pre.as_ref()), ("output", c.post.as_ref())] {
            let computed = commitment_json(comm);
            let rec = case.get(side);
            note_unhandled(
                &mut tally,
                rec.unwrap_or(&Value::Null),
                &computed.keys().map(String::as_str).collect::<Vec<_>>(),
                &format!("checks[].{side}."),
            );
            for (k, v) in &computed {
                tally.cmp(&name, &format!("{side}.{k}"), v, member(rec, k));
            }
        }

        compare_undefined_fields(&mut tally, &name, case, &world, &c);
    }
    tally
}

/// Fields the specification does not define, compared under the readings declared in the
/// report. They never decide PASS or FAIL.
fn compare_undefined_fields(
    tally: &mut Tally,
    name: &str,
    case: &Value,
    world: &WorldV0,
    c: &Computed,
) {
    let rejected = c.t.effects.outcome == Outcome::Rejected;
    tally.info(name, "rejected", &json!(rejected), case.get("rejected"));
    let (pre_j, post_j) = (
        commitment_json(c.pre.as_ref()),
        commitment_json(c.post.as_ref()),
    );
    let unchanged = ROOT_FIELDS
        .iter()
        .filter(|f| pre_j[**f] == post_j[**f])
        .map(|f| (*f).to_owned());
    tally.info(
        name,
        "roots_unchanged (as a set)",
        &label_set(unchanged),
        recorded_set(case.get("roots_unchanged")).as_ref(),
    );
    let writes = label_set(changed_keys(world, &c.t.next).iter().map(key_label));
    tally.info(
        name,
        "writes (as a set)",
        &writes,
        recorded_set(case.get("writes")).as_ref(),
    );
    tally.info(
        name,
        "keys_written",
        &json!(writes.as_array().map_or(0, Vec::len)),
        case.get("keys_written"),
    );
}

const EXPANSION_OUTPUTS: [&str; 5] = [
    "input_commitment",
    "effects",
    "output_state",
    "output_commitment",
    "transcript_hash",
];

fn compare_hashes(tally: &mut Tally, name: &str, case: &Value, manifest: Hash32, cmd: Hash32) {
    tally.cmp(
        name,
        "manifest_hash",
        &jh(&manifest),
        case.get("manifest_hash"),
    );
    tally.cmp(name, "command_hash", &jh(&cmd), case.get("command_hash"));
}

const EXPANSION_HANDLED: [&str; 12] = [
    "name",
    "manifest",
    "manifest_hash",
    "input_state",
    "input_commitment",
    "command",
    "command_hash",
    "context",
    "effects",
    "output_state",
    "output_commitment",
    "transcript_hash",
];

fn compare_expansion_case(tally: &mut Tally, name: &str, case: &Value, c: &Computed) {
    compare_hashes(tally, name, case, c.manifest_hash, c.command_hash);
    for (side, comm) in [
        ("input_commitment", c.pre.as_ref()),
        ("output_commitment", c.post.as_ref()),
    ] {
        let computed = commitment_json(comm);
        let rec = case.get(side);
        note_unhandled(
            tally,
            rec.unwrap_or(&Value::Null),
            &ROOT_FIELDS,
            &format!("cases[].{side}."),
        );
        for k in ROOT_FIELDS {
            tally.cmp(name, &format!("{side}.{k}"), &computed[k], member(rec, k));
        }
    }
    compare_effects_and_state(tally, name, case, c);
    let transcript = match (c.pre, c.post) {
        (Some(pre), Some(post)) => jh(&TranscriptV0 {
            command_hash: c.command_hash,
            prev_root: pre.world_root(),
            next_root: post.world_root(),
            effects: c.t.effects,
        }
        .hash()),
        _ => Value::String("<undefined: world root undefined>".into()),
    };
    tally.cmp(
        name,
        "transcript_hash",
        &transcript,
        case.get("transcript_hash"),
    );
}

pub fn check_expansion(doc: &Value) -> Tally {
    let mut tally = Tally {
        kind: "expansion cases",
        ..Tally::default()
    };
    tally.cmp(
        "<file>",
        "commitment_version",
        &Value::String(DOMAIN_WORLD_V1.into()),
        doc.get("commitment_version"),
    );
    note_unhandled(
        &mut tally,
        doc,
        &["cases", "commitment_version", "coverage"],
        "",
    );
    let cases = doc
        .get("cases")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut outcomes = [0usize; 4];
    let mut by_reason = [0usize; 11];
    for case in &cases {
        tally.checks += 1;
        let name = case
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("<unnamed>")
            .to_owned();
        note_unhandled(&mut tally, case, &EXPANSION_HANDLED, "cases[].");
        let (_, c) = match compute(case, &mut tally, &name) {
            Ok(x) => x,
            Err(Unrun::Input(e)) => {
                tally.errors.push((name, e));
                continue;
            }
            Err(Unrun::Refused {
                why,
                manifest_hash,
                command_hash,
            }) => {
                compare_hashes(&mut tally, &name, case, manifest_hash, command_hash);
                compare_refusal(&mut tally, &name, case, &why, &EXPANSION_OUTPUTS);
                continue;
            }
        };
        outcomes[c.t.effects.outcome as usize] += 1;
        if let Some(r) = c.t.effects.reject_reason {
            by_reason[r as usize] += 1;
        }
        compare_expansion_case(&mut tally, &name, case, &c);
    }
    let coverage = json!({
        "cases": tally.checks,
        "created": outcomes[Outcome::Created as usize],
        "roll_failed": outcomes[Outcome::RollFailed as usize],
        "rejected": outcomes[Outcome::Rejected as usize],
        "rejected_by_reason": by_reason,
    });
    tally.info("<file>", "coverage", &coverage, doc.get("coverage"));
    tally
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::tests::fixture;

    fn case_of(w: &WorldV0) -> Value {
        let (_, cmd, ctx, m) = fixture();
        json!({
            "input_state": world_json(w),
            "manifest": {
                "round_period": jd(m.round_period),
                "entropy_safety_margin": jd(m.entropy_safety_margin),
                "catch_rate_bp": m.catch_rate_bp.to_string(),
            },
            "command": { "subject": jh(&cmd.subject), "permit_id": jh(&cmd.permit_id) },
            "context": {
                "position": jd(ctx.position), "epoch": jd(ctx.epoch),
                "entropy_round": jd(ctx.entropy_round), "entropy_value": jh(&ctx.entropy_value),
            },
        })
    }

    #[test]
    fn conflicting_records_never_reach_the_kernel() {
        let (mut w, ..) = fixture();
        let mut tally = Tally::default();
        assert!(compute(&case_of(&w), &mut tally, "ok").is_ok());
        let mut other = w.permits[0].clone();
        other.status = 2;
        w.permits.push(other);
        let err = compute(&case_of(&w), &mut tally, "conflict").err();
        assert!(matches!(err, Some(Unrun::Refused { why, .. }) if why.contains("no mapping")));
        assert_eq!(tally.max_reads, 4);
        assert_eq!(tally.outcomes.iter().sum::<usize>(), 1);
        assert!(tally.invariant_failures.is_empty());
    }

    #[test]
    fn a_refusal_agrees_only_with_recorded_absence() {
        let mut tally = Tally::default();
        let case = json!({ "effects": null, "output_state": { "subjects": [] } });
        compare_refusal(&mut tally, "c", &case, "why", &EXPANSION_OUTPUTS);
        assert_eq!(
            (tally.refused, tally.compared),
            (1, EXPANSION_OUTPUTS.len())
        );
        let fields: Vec<&str> = tally.mismatches.iter().map(|m| m.field.as_str()).collect();
        assert_eq!(fields, ["output_state"]);
    }

    #[test]
    fn a_repeated_identical_entry_is_kernel_input() {
        let (mut w, ..) = fixture();
        w.subjects.push(w.subjects[1]);
        let mut tally = Tally::default();
        let (_, c) =
            compute(&case_of(&w), &mut tally, "repeat").unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(
            c.t.effects.reject_reason,
            Some(crate::t1::RejectReason::InvalidState)
        );
        assert!(c.pre.is_some() && c.pre == c.post);
        assert!(tally.invariant_failures.is_empty());
    }
}
