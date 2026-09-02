//! Transition 1 (capture acceptance) objects and semantics, from
//! spec/canonical-encoding.md §6 and spec/protocol.md §§2,5,6,10.

use crate::enc::{
    Hash32, protocol_hash, put_hash32, put_optional, put_seq, put_u8, put_u32, put_u64,
};

pub const ENCOUNTER_CLASS_COMMON: u8 = 1;
pub const STATUS_RESERVED: u8 = 1;
pub const STATUS_CONSUMED: u8 = 2;
pub const OUTCOME_CREATED: u8 = 1;
pub const OUTCOME_ROLL_FAILED: u8 = 2;
pub const OUTCOME_REJECTED: u8 = 3;

// RejectReason discriminants as assigned by canonical-encoding.md §6.
pub const REJECT_UNKNOWN_SUBJECT: u8 = 1;
pub const REJECT_UNKNOWN_PERMIT: u8 = 2;
pub const REJECT_PERMIT_NOT_RESERVED: u8 = 3;
pub const REJECT_WRONG_SUBJECT: u8 = 4;
pub const REJECT_PERMIT_EXPIRED: u8 = 5;
pub const REJECT_NO_CAPABILITY: u8 = 6;
pub const REJECT_ENTROPY_MISMATCH: u8 = 7;
pub const REJECT_WRONG_EPOCH: u8 = 8;
pub const REJECT_INVALID_STATE: u8 = 9;

#[derive(Clone)]
pub struct BlockmonRecord {
    pub creature_id: Hash32,
    pub owner: Hash32,
    pub origin_permit: Hash32,
}

#[derive(Clone)]
pub struct PermitRecord {
    pub permit_id: Hash32,
    pub subject: Hash32,
    pub encounter_class: u8,
    pub expiry_position: u64,
    pub status: u8,
}

#[derive(Clone)]
pub struct Supply {
    pub epoch: u64,
    pub envelope: u64,
    pub minted: u64,
    pub consumed: u64,
    pub created: u64,
}

#[derive(Clone)]
pub struct WorldV0 {
    pub subjects: Vec<Hash32>,
    pub blockmon: Vec<BlockmonRecord>,
    pub permits: Vec<PermitRecord>,
    pub supply: Supply,
}

pub struct ManifestV0 {
    pub round_period: u64,
    pub entropy_safety_margin: u64,
    pub catch_rate_bp: u32,
}

pub struct CaptureCommand {
    pub subject: Hash32,
    pub permit_id: Hash32,
}

pub struct EffectsV0 {
    pub outcome: u8,
    pub reject_reason: Option<u8>,
    pub roll: Option<u64>,
    pub creature: Option<Hash32>,
}

/// `ContextV0` kernel input record, canonical-encoding.md §6 (never wire-encoded).
pub struct Context {
    pub position: u64,
    pub epoch: u64,
    pub entropy_round: u64,
    pub entropy_value: Hash32,
}

pub fn encode_blockmon(out: &mut Vec<u8>, r: &BlockmonRecord) {
    put_hash32(out, &r.creature_id);
    put_hash32(out, &r.owner);
    put_hash32(out, &r.origin_permit);
}

pub fn encode_permit(out: &mut Vec<u8>, r: &PermitRecord) {
    put_hash32(out, &r.permit_id);
    put_hash32(out, &r.subject);
    put_u8(out, r.encounter_class);
    put_u64(out, r.expiry_position);
    put_u8(out, r.status);
}

pub fn encode_supply(out: &mut Vec<u8>, s: &Supply) {
    put_u64(out, s.epoch);
    put_u64(out, s.envelope);
    put_u64(out, s.minted);
    put_u64(out, s.consumed);
    put_u64(out, s.created);
}

pub fn encode_world(w: &WorldV0) -> Vec<u8> {
    let mut out = Vec::new();
    put_seq(&mut out, &w.subjects, put_hash32);
    put_seq(&mut out, &w.blockmon, encode_blockmon);
    put_seq(&mut out, &w.permits, encode_permit);
    encode_supply(&mut out, &w.supply);
    out
}

pub fn encode_manifest(m: &ManifestV0) -> Vec<u8> {
    let mut out = Vec::new();
    put_u64(&mut out, m.round_period);
    put_u64(&mut out, m.entropy_safety_margin);
    put_u32(&mut out, m.catch_rate_bp);
    out
}

pub fn encode_command(c: &CaptureCommand) -> Vec<u8> {
    let mut out = Vec::new();
    put_hash32(&mut out, &c.subject);
    put_hash32(&mut out, &c.permit_id);
    out
}

pub fn encode_effects(out: &mut Vec<u8>, e: &EffectsV0) {
    put_u8(out, e.outcome);
    put_optional(out, e.reject_reason.as_ref(), |o, r| put_u8(o, *r));
    put_optional(out, e.roll.as_ref(), |o, r| put_u64(o, *r));
    put_optional(out, e.creature.as_ref(), put_hash32);
}

pub fn world_root(w: &WorldV0) -> Hash32 {
    protocol_hash("blockmon/world/v0", &encode_world(w))
}

pub fn manifest_hash(m: &ManifestV0) -> Hash32 {
    protocol_hash("blockmon/manifest/v0", &encode_manifest(m))
}

pub fn command_hash(c: &CaptureCommand) -> Hash32 {
    protocol_hash("blockmon/capture-cmd/v0", &encode_command(c))
}

pub fn creature_id(permit_id: &Hash32) -> Hash32 {
    protocol_hash("blockmon/creature-id/v0", permit_id)
}

pub fn capture_seed(entropy_value: &Hash32, permit_id: &Hash32, mhash: &Hash32) -> Hash32 {
    let mut payload = Vec::with_capacity(96);
    payload.extend_from_slice(entropy_value);
    payload.extend_from_slice(permit_id);
    payload.extend_from_slice(mhash);
    protocol_hash("blockmon/capture-roll/v0", &payload)
}

pub const fn assigned_round(p: u64, m: &ManifestV0) -> u64 {
    p / m.round_period + 1 + m.entropy_safety_margin
}

pub fn transcript_hash(
    cmd_hash: &Hash32,
    prev_root: &Hash32,
    next_root: &Hash32,
    effects: &EffectsV0,
) -> Hash32 {
    let mut out = Vec::new();
    put_hash32(&mut out, cmd_hash);
    put_hash32(&mut out, prev_root);
    put_hash32(&mut out, next_root);
    encode_effects(&mut out, effects);
    protocol_hash("blockmon/transition/v0", &out)
}

fn strictly_ascending(keys: impl Iterator<Item = Hash32>) -> bool {
    let mut prev: Option<Hash32> = None;
    for k in keys {
        if let Some(p) = &prev
            && *p >= k
        {
            return false;
        }
        prev = Some(k);
    }
    true
}

/// Canonical form per §6: `subjects`, `blockmon`, `permits` strictly ascending
/// byte-lexicographically.
pub fn world_is_canonical(w: &WorldV0) -> bool {
    strictly_ascending(w.subjects.iter().copied())
        && strictly_ascending(w.blockmon.iter().map(|b| b.creature_id))
        && strictly_ascending(w.permits.iter().map(|p| p.permit_id))
}

/// `INVALID_STATE`'s totality-guard predicate (§6): the world is valid kernel
/// input iff it is in canonical form, every enum field holds an assigned value,
/// supply satisfies created ≤ consumed ≤ minted ≤ envelope, and the blockmon
/// count equals created (extant == created, protocol.md §10, no exits in T1);
/// the manifest is valid iff `round_period` ≥ 1.
fn invalid_state(w: &WorldV0, m: &ManifestV0) -> bool {
    let enums_valid = w.permits.iter().all(|p| {
        p.encounter_class == ENCOUNTER_CLASS_COMMON
            && (p.status == STATUS_RESERVED || p.status == STATUS_CONSUMED)
    });
    let s = &w.supply;
    let supply_valid = s.created <= s.consumed && s.consumed <= s.minted && s.minted <= s.envelope;
    let extant_matches = u64::try_from(w.blockmon.len()).is_ok_and(|n| n == s.created);
    m.round_period == 0
        || !world_is_canonical(w)
        || !enums_valid
        || !supply_valid
        || !extant_matches
}

pub struct Seed(pub Option<Hash32>);

fn rejected(prev: &WorldV0, reason: u8) -> (WorldV0, EffectsV0, Seed) {
    (
        prev.clone(),
        EffectsV0 {
            outcome: OUTCOME_REJECTED,
            reject_reason: Some(reason),
            roll: None,
            creature: None,
        },
        Seed(None),
    )
}

/// Transition 1: capture acceptance. Total (protocol.md §2): every failure is a
/// defined rejection that consumes nothing and returns the input state
/// byte-identical; the first failing precondition, in §6's normative order, is
/// the reason. Once the roll executes, the permit and one capture-class
/// capability are consumed unconditionally (consume-on-attempt, protocol.md §6).
pub fn transition1(
    prev: &WorldV0,
    cmd: &CaptureCommand,
    ctx: &Context,
    manifest: &ManifestV0,
) -> (WorldV0, EffectsV0, Seed) {
    if invalid_state(prev, manifest) {
        return rejected(prev, REJECT_INVALID_STATE);
    }
    if ctx.epoch != prev.supply.epoch {
        return rejected(prev, REJECT_WRONG_EPOCH);
    }
    if ctx.entropy_round != assigned_round(ctx.position, manifest) {
        return rejected(prev, REJECT_ENTROPY_MISMATCH);
    }
    if prev.subjects.binary_search(&cmd.subject).is_err() {
        return rejected(prev, REJECT_UNKNOWN_SUBJECT);
    }
    let Ok(pi) = prev
        .permits
        .binary_search_by(|p| p.permit_id.cmp(&cmd.permit_id))
    else {
        return rejected(prev, REJECT_UNKNOWN_PERMIT);
    };
    let permit = &prev.permits[pi];
    if permit.status != STATUS_RESERVED {
        return rejected(prev, REJECT_PERMIT_NOT_RESERVED);
    }
    if permit.subject != cmd.subject {
        return rejected(prev, REJECT_WRONG_SUBJECT);
    }
    // expiry_position is exclusive: the permit is spendable strictly before it.
    if ctx.position >= permit.expiry_position {
        return rejected(prev, REJECT_PERMIT_EXPIRED);
    }
    if prev.supply.consumed >= prev.supply.minted {
        return rejected(prev, REJECT_NO_CAPABILITY);
    }

    let mhash = manifest_hash(manifest);
    let seed = capture_seed(&ctx.entropy_value, &cmd.permit_id, &mhash);
    let mut roll_bytes = [0u8; 8];
    roll_bytes.copy_from_slice(&seed[0..8]);
    let roll = u64::from_be_bytes(roll_bytes) % 10000;
    let success = roll < u64::from(manifest.catch_rate_bp);

    // next is a field-for-field clone of prev, so pi still addresses the permit
    let mut next = prev.clone();
    next.permits[pi].status = STATUS_CONSUMED;
    next.supply.consumed += 1;

    let effects = if success {
        let cid = creature_id(&cmd.permit_id);
        let record = BlockmonRecord {
            creature_id: cid,
            owner: cmd.subject,
            origin_permit: cmd.permit_id,
        };
        let at = next
            .blockmon
            .binary_search_by(|b| b.creature_id.cmp(&cid))
            .unwrap_err();
        next.blockmon.insert(at, record);
        next.supply.created += 1;
        EffectsV0 {
            outcome: OUTCOME_CREATED,
            reject_reason: None,
            roll: Some(roll),
            creature: Some(cid),
        }
    } else {
        EffectsV0 {
            outcome: OUTCOME_ROLL_FAILED,
            reject_reason: None,
            roll: Some(roll),
            creature: None,
        }
    };
    (next, effects, Seed(Some(seed)))
}
