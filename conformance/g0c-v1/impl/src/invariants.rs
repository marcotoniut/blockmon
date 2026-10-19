//! Normative invariants asserted on every computed transition, independent of any corpus:
//! protocol.md §10 conservation, §6 consume-on-attempt and no reuse, canonical-encoding.md §6
//! rejection semantics and §7 update and proof consistency.

use crate::encoding::ZERO32;
use crate::kernel::{KeyRef, Transition, transition, validity_violation};
use crate::smt::{self, Proof, Tag, Update};
use crate::t1::{
    BlockmonRecord, CaptureCommand, ContextV0, ManifestV0, Outcome, PermitRecord, ROLL_MODULUS,
    RejectReason, STATUS_CONSUMED, STATUS_RESERVED, WorldV0, creature_id,
};
use crate::world::{DomainLeaves, WorldStore, commit, read_state};

/// §10 identities that a single world value can witness.
pub fn conservation(world: &WorldV0) -> Vec<String> {
    let s = &world.supply;
    let mut v = Vec::new();
    if s.minted > s.envelope {
        v.push(format!(
            "scheduled envelope {} < minted {}",
            s.envelope, s.minted
        ));
    }
    if s.consumed > s.minted {
        v.push(format!(
            "consumed {} > minted {} (minted = consumed + expired)",
            s.consumed, s.minted
        ));
    }
    if s.created > s.consumed {
        v.push(format!("creations {} > consumed {}", s.created, s.consumed));
    }
    if u64::try_from(world.blockmon.len()).ok() != Some(s.created) {
        v.push(format!(
            "extant {} != created {} (no exits in T1)",
            world.blockmon.len(),
            s.created
        ));
    }
    if !world
        .blockmon
        .windows(2)
        .all(|w| w[0].creature_id < w[1].creature_id)
    {
        v.push("a Blockmon key is listed more than once or out of order".into());
    }
    v
}

fn value_of(world: &WorldV0, k: &KeyRef) -> Option<Vec<u8>> {
    match k.tag {
        Tag::Subject => world.subjects.contains(&k.key).then(Vec::new),
        Tag::Blockmon => world
            .blockmon
            .iter()
            .find(|b| b.creature_id == k.key)
            .map(BlockmonRecord::encode),
        Tag::Encounter => world
            .permits
            .iter()
            .find(|p| p.permit_id == k.key)
            .map(PermitRecord::encode),
        Tag::Supply => (k.key == ZERO32).then(|| world.supply.encode()),
    }
}

/// Each read is proved with the siblings the store serves, gated against the state walk.
fn check_read_proofs(
    pre: &WorldV0,
    leaves: &DomainLeaves,
    store: &WorldStore,
    reads: &[KeyRef],
    out: &mut Vec<String>,
) {
    let c = &store.commitment();
    for k in reads {
        let sib = store.domain(k.tag).siblings(&k.key);
        if sib != smt::siblings(leaves.get(k.tag), &k.key) {
            out.push(format!(
                "store siblings for {} differ from the walk",
                key_label(k)
            ));
        }
        let value = value_of(pre, k);
        let proof = Proof {
            tag: k.tag as u8,
            key: &k.key,
            value: value.as_deref(),
            siblings: &sib,
        };
        if let Err(e) = smt::verify_proof(&proof, c.field(k.tag), c) {
            out.push(format!(
                "read proof for {}:{} fails: {e:?}",
                k.tag.name(),
                crate::encoding::hex32(&k.key)
            ));
        }
    }
}

fn check_updates(pre: &WorldV0, post: &WorldV0, writes: &[KeyRef], out: &mut Vec<String>) {
    let (Ok(pre_l), Ok(post_l)) = (DomainLeaves::of(pre), DomainLeaves::of(post)) else {
        out.push("valid pre or post state has a repeated key".into());
        return;
    };
    let (pre_c, post_c) = (pre_l.commitment(), post_l.commitment());
    for tag in [Tag::Subject, Tag::Blockmon, Tag::Encounter, Tag::Supply] {
        let touched: Vec<&KeyRef> = writes.iter().filter(|k| k.tag == tag).collect();
        if touched.is_empty() && pre_c.field(tag) != post_c.field(tag) {
            out.push(format!(
                "{} root moved without a write to that domain",
                tag.name()
            ));
        }
        if touched.len() > 1 {
            out.push(format!("more than one {} key written", tag.name()));
        }
        for k in touched {
            let sib = smt::siblings(pre_l.get(tag), &k.key);
            let (old, new) = (value_of(pre, k), value_of(post, k));
            let u = Update {
                tag: tag as u8,
                key: &k.key,
                old: old.as_deref(),
                new: new.as_deref(),
                siblings: &sib,
                claimed_pre_root: *pre_c.field(tag),
            };
            match smt::apply_update(&u) {
                Ok(r) if r == *post_c.field(tag) => {}
                other => out.push(format!(
                    "authenticated update of {}:{} gives {other:?}, full derivation differs",
                    tag.name(),
                    crate::encoding::hex32(&k.key)
                )),
            }
        }
    }
    if post_c.supply_commitment() != post_c.supply_root {
        out.push("supply_commitment != supply_root".into());
    }
}

/// The kernel's declared writes are exactly the keys whose value changed, with their true old
/// and new values. Moving the input commitment by them reaches the full derivation, both as the
/// producer moves it and as anchored updates a verifier checks.
fn check_declared_writes(pre: &WorldV0, t: &Transition, out: &mut Vec<String>) {
    let mut declared: Vec<KeyRef> = t.writes.iter().map(|w| w.at).collect();
    declared.sort_unstable();
    if declared != changed_keys(pre, &t.next) {
        out.push("declared writes differ from the keys whose value changed".into());
    }
    for w in &t.writes {
        if w.old != value_of(pre, &w.at) || w.new != value_of(&t.next, &w.at) {
            out.push(format!(
                "declared write of {} misstates a value",
                key_label(&w.at)
            ));
        }
    }
    let (Ok(store), Ok(leaves)) = (WorldStore::genesis(pre), DomainLeaves::of(pre)) else {
        out.push("valid pre-state has no commitment".into());
        return;
    };
    for w in &t.writes {
        if store.domain(w.at.tag).siblings(&w.at.key)
            != smt::siblings(leaves.get(w.at.tag), &w.at.key)
        {
            out.push(format!(
                "store siblings for written {} differ from the walk",
                key_label(&w.at)
            ));
        }
    }
    let full = commit(&t.next).ok();
    let moved = store.clone().advance(&t.writes);
    if moved.as_ref().ok() != full.as_ref() {
        out.push(format!(
            "commitment moved by the producer ({moved:?}) differs from full derivation"
        ));
    }
    let verified = store.clone().verify_updates(&t.writes);
    if verified.as_ref().ok() != full.as_ref() {
        out.push(format!(
            "commitment moved by anchored updates ({verified:?}) differs from full derivation"
        ));
    }
    for order in permutations(&t.writes) {
        let by_producer = store.clone().advance(&order);
        let by_verifier = store.clone().verify_updates(&order);
        if by_producer.as_ref().ok() != full.as_ref() || by_verifier.as_ref().ok() != full.as_ref()
        {
            out.push("the write batch anchors or lands differently in another order".into());
            break;
        }
    }
}

/// Every ordering of `items`; §7 makes a batch's anchoring and result independent of it.
fn permutations<T: Clone>(items: &[T]) -> Vec<Vec<T>> {
    if items.len() <= 1 {
        return vec![items.to_vec()];
    }
    (0..items.len())
        .flat_map(|i| {
            let mut rest = items.to_vec();
            let head = rest.remove(i);
            permutations(&rest).into_iter().map(move |mut tail| {
                tail.insert(0, head.clone());
                tail
            })
        })
        .collect()
}

/// Keys whose committed value differs between the two worlds.
pub fn changed_keys(pre: &WorldV0, post: &WorldV0) -> Vec<KeyRef> {
    let mut keys: Vec<KeyRef> = Vec::new();
    let all = |w: &WorldV0| {
        let mut v: Vec<KeyRef> = w
            .subjects
            .iter()
            .map(|k| KeyRef {
                tag: Tag::Subject,
                key: *k,
            })
            .collect();
        v.extend(w.blockmon.iter().map(|b| KeyRef {
            tag: Tag::Blockmon,
            key: b.creature_id,
        }));
        v.extend(w.permits.iter().map(|p| KeyRef {
            tag: Tag::Encounter,
            key: p.permit_id,
        }));
        v.push(KeyRef {
            tag: Tag::Supply,
            key: ZERO32,
        });
        v
    };
    for k in all(pre).into_iter().chain(all(post)) {
        if !keys.contains(&k) && value_of(pre, &k) != value_of(post, &k) {
            keys.push(k);
        }
    }
    keys.sort_unstable();
    keys
}

fn check_executed(
    pre: &WorldV0,
    cmd: &CaptureCommand,
    ctx: &ContextV0,
    manifest: &ManifestV0,
    t: &Transition,
    out: &mut Vec<String>,
) {
    let post = &t.next;
    if let Some(why) = validity_violation(pre, manifest) {
        out.push(format!("executed on invalid input: {why}"));
    }
    if let Some(why) = validity_violation(post, manifest) {
        out.push(format!("post-state is not valid kernel input: {why}"));
    }
    out.extend(
        conservation(post)
            .into_iter()
            .map(|m| format!("post-state §10: {m}")),
    );
    let (a, b) = (&pre.supply, &post.supply);
    let created = t.effects.outcome == Outcome::Created;
    if (a.epoch, a.envelope, a.minted) != (b.epoch, b.envelope, b.minted) {
        out.push("epoch, envelope or minted changed".into());
    }
    if b.consumed != a.consumed + 1 {
        out.push("attempt did not consume exactly one capability".into());
    }
    if b.created != a.created + u64::from(created) {
        out.push("created changed other than by the creation".into());
    }
    if i128::from(b.created) - i128::from(a.created)
        > i128::from(b.consumed) - i128::from(a.consumed)
    {
        out.push("transition created more than it consumed".into());
    }
    if pre.subjects != post.subjects {
        out.push("subjects changed".into());
    }
    let permits_ok = pre.permits.len() == post.permits.len()
        && pre.permits.iter().zip(&post.permits).all(|(p, q)| {
            if p.permit_id == cmd.permit_id {
                p.status == STATUS_RESERVED
                    && q.status == STATUS_CONSUMED
                    && (p.permit_id, p.subject, p.encounter_class, p.expiry_position)
                        == (q.permit_id, q.subject, q.encounter_class, q.expiry_position)
            } else {
                p == q
            }
        });
    if !permits_ok {
        out.push(
            "permits changed other than the commanded permit going RESERVED to CONSUMED".into(),
        );
    }
    let mut expected = pre.blockmon.clone();
    if created {
        let id = creature_id(&cmd.permit_id);
        if t.effects.creature != Some(id) {
            out.push("effects.creature is not creature_id(permit_id)".into());
        }
        expected.push(BlockmonRecord {
            creature_id: id,
            owner: cmd.subject,
            origin_permit: cmd.permit_id,
        });
        expected.sort_unstable_by_key(|r| r.creature_id);
    }
    if post.blockmon != expected {
        out.push("blockmon changed other than by exactly one owned creation".into());
    }
    match t.effects.roll {
        Some(r) if r < ROLL_MODULUS => {
            if (r < u64::from(manifest.catch_rate_bp)) != created {
                out.push("outcome disagrees with roll < catch_rate_bp".into());
            }
        }
        _ => out.push("roll absent or out of range".into()),
    }
    if holds_creature(pre, cmd) {
        out.push("executed although creature_id(permit_id) was already a blockmon key".into());
    }
    let replay = transition(post, cmd, ctx, manifest);
    if replay.effects.outcome != Outcome::Rejected || replay.next != *post {
        out.push("re-applying the executed command was not a rejection".into());
    }
    check_updates(pre, post, &changed_keys(pre, post), out);
    check_declared_writes(pre, t, out);
}

fn holds_creature(world: &WorldV0, cmd: &CaptureCommand) -> bool {
    let id = creature_id(&cmd.permit_id);
    world.blockmon.iter().any(|b| b.creature_id == id)
}

/// §6: the state reader returns kernel input as given, and a re-run reads it the same way. Only
/// forms `INVALID_STATE` rejects separate the reader from the strict decoder.
fn check_reading(
    pre: &WorldV0,
    cmd: &CaptureCommand,
    ctx: &ContextV0,
    manifest: &ManifestV0,
    t: &Transition,
    out: &mut Vec<String>,
) {
    let bytes = pre.encode();
    let reread = read_state(&bytes);
    if reread.as_ref() != Ok(pre) {
        out.push(format!(
            "the state reader gives {reread:?} for kernel input"
        ));
    }
    if reread.map(|w| transition(&w, cmd, ctx, manifest)).as_ref() != Ok(t) {
        out.push("a re-run on the state as read again differs".into());
    }
    let invalid_state = t.effects.reject_reason == Some(RejectReason::InvalidState);
    match WorldV0::decode(&bytes) {
        Ok(w) if w != *pre => out.push("the strict decoder changed the listing".into()),
        Err(e) if !invalid_state => out.push(format!(
            "input the strict decoder refuses ({e:?}) was not rejected as INVALID_STATE"
        )),
        _ => {}
    }
}

/// Every violated invariant, as text. Empty means the transition is sound.
pub fn check(
    pre: &WorldV0,
    cmd: &CaptureCommand,
    ctx: &ContextV0,
    manifest: &ManifestV0,
    t: &Transition,
) -> Vec<String> {
    let mut out = Vec::new();
    if WorldStore::genesis(pre).ok().map(|s| s.commitment()) != commit(pre).ok() {
        out.push("genesis store roots differ from full derivation".into());
    }
    if !t.effects.is_well_formed() {
        out.push("effects violate the EffectsV0 presence rules".into());
    }
    check_reading(pre, cmd, ctx, manifest, t, &mut out);
    if t.effects.outcome == Outcome::Rejected {
        if t.next.encode() != pre.encode() || t.next != *pre {
            out.push("rejection did not return the input state byte-identical".into());
        }
        let invalid = validity_violation(pre, manifest).is_some();
        if invalid != (t.effects.reject_reason == Some(RejectReason::InvalidState)) {
            out.push("INVALID_STATE disagrees with the validity predicate".into());
        }
        if !invalid {
            out.extend(
                conservation(pre)
                    .into_iter()
                    .map(|m| format!("valid pre-state §10: {m}")),
            );
        }
        if t.effects.reject_reason == Some(RejectReason::CreatureExists)
            && !holds_creature(pre, cmd)
        {
            out.push(
                "CREATURE_EXISTS without creature_id(permit_id) in the blockmon domain".into(),
            );
        }
        if !t.writes.is_empty() {
            out.push("rejection declared writes".into());
        }
    } else {
        check_executed(pre, cmd, ctx, manifest, t, &mut out);
    }
    if validity_violation(pre, manifest).is_none()
        && let (Ok(leaves), Ok(store)) = (DomainLeaves::of(pre), WorldStore::genesis(pre))
    {
        check_read_proofs(pre, &leaves, &store, &t.reads, &mut out);
    }
    out
}

pub fn key_label(k: &KeyRef) -> String {
    format!("{}:{}", k.tag.name(), crate::encoding::hex32(&k.key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::tests::fixture;
    use crate::t1::EffectsV0;

    #[test]
    fn sound_transitions_report_nothing() {
        let (w, cmd, ctx, m) = fixture();
        for rate in [0, 10_000] {
            let m = ManifestV0 {
                catch_rate_bp: rate,
                ..m
            };
            let t = transition(&w, &cmd, &ctx, &m);
            assert_eq!(check(&w, &cmd, &ctx, &m, &t), Vec::<String>::new());
        }
        let bad = ContextV0 { epoch: 99, ..ctx };
        let t = transition(&w, &cmd, &bad, &m);
        assert_eq!(check(&w, &cmd, &bad, &m, &t), Vec::<String>::new());
    }

    #[test]
    fn creature_exists_rejection_reports_nothing() {
        let (w, cmd, ctx, m) = crate::kernel::tests::creature_present();
        let t = transition(&w, &cmd, &ctx, &m);
        assert_eq!(t.effects.reject_reason, Some(RejectReason::CreatureExists));
        assert_eq!(check(&w, &cmd, &ctx, &m, &t), Vec::<String>::new());
    }

    #[test]
    fn an_overwriting_creation_is_caught() {
        let (w, cmd, ctx, m) = crate::kernel::tests::creature_present();
        let mut t = transition(&w, &cmd, &ctx, &m);
        t.effects = EffectsV0 {
            outcome: Outcome::Created,
            reject_reason: None,
            roll: Some(0),
            creature: Some(creature_id(&cmd.permit_id)),
        };
        assert!(!check(&w, &cmd, &ctx, &m, &t).is_empty());
    }

    #[test]
    fn a_misdeclared_write_is_caught() {
        let (w, cmd, ctx, m) = fixture();
        let mut t = transition(&w, &cmd, &ctx, &m);
        t.writes.pop();
        assert!(!check(&w, &cmd, &ctx, &m, &t).is_empty());
    }

    #[test]
    fn a_minting_transition_is_caught() {
        let (w, cmd, ctx, m) = fixture();
        let mut t = transition(&w, &cmd, &ctx, &m);
        t.next.supply.created += 1;
        assert!(!check(&w, &cmd, &ctx, &m, &t).is_empty());
    }

    #[test]
    fn a_releasing_failure_is_caught() {
        let (w, cmd, ctx, m) = fixture();
        let m = ManifestV0 {
            catch_rate_bp: 0,
            ..m
        };
        let mut t = transition(&w, &cmd, &ctx, &m);
        t.next = w.clone();
        assert!(!check(&w, &cmd, &ctx, &m, &t).is_empty());
    }

    #[test]
    fn permutations_are_complete_and_distinct() {
        let all = permutations(&[1, 2, 3]);
        let distinct: std::collections::BTreeSet<_> = all.iter().cloned().collect();
        assert_eq!((all.len(), distinct.len()), (6, 6));
        assert_eq!(permutations::<u8>(&[]), vec![Vec::<u8>::new()]);
    }

    #[test]
    fn changed_keys_of_a_creation() {
        let (w, cmd, ctx, m) = fixture();
        let t = transition(&w, &cmd, &ctx, &m);
        let labels: Vec<String> = changed_keys(&w, &t.next).iter().map(key_label).collect();
        assert_eq!(labels.len(), 3);
        assert!(labels[0].starts_with("blockmon:"));
        assert!(labels[1].starts_with("encounter:"));
        assert!(labels[2].starts_with("supply:"));
    }
}
