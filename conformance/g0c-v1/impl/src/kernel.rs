//! The Transition 1 kernel: capture acceptance (canonical-encoding.md §6).

use crate::encoding::{Hash32, ZERO32};
use crate::smt::Tag;
use crate::t1::{
    BlockmonRecord, CaptureCommand, ContextV0, ENCOUNTER_CLASSES, EffectsV0, ManifestV0, Outcome,
    PERMIT_STATUSES, RejectReason, STATUS_CONSUMED, STATUS_RESERVED, WorldV0, capture_seed,
    creature_id, roll, strictly_ascending,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct KeyRef {
    pub tag: Tag,
    pub key: Hash32,
}

/// One authenticated-key update: the encoded record before and after, `None` for absence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Write {
    pub at: KeyRef,
    pub old: Option<Vec<u8>>,
    pub new: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transition {
    pub next: WorldV0,
    pub effects: EffectsV0,
    /// Authenticated keys the executed checks consulted, in first-consultation order. Not a
    /// protocol object; kept for reporting and for proof checks.
    pub reads: Vec<KeyRef>,
    /// The key updates that move the commitment from the input state to `next`; empty on
    /// rejection.
    pub writes: Vec<Write>,
}

/// The `INVALID_STATE` predicate: `None` when `world` and `manifest` are valid kernel input.
pub fn validity_violation(world: &WorldV0, manifest: &ManifestV0) -> Option<&'static str> {
    let s = &world.supply;
    if manifest.round_period == 0 {
        Some("manifest round_period = 0")
    } else if !strictly_ascending(&world.subjects, |k| k) {
        Some("subjects not strictly ascending")
    } else if !strictly_ascending(&world.blockmon, |b| &b.creature_id) {
        Some("blockmon not strictly ascending by creature_id")
    } else if !strictly_ascending(&world.permits, |p| &p.permit_id) {
        Some("permits not strictly ascending by permit_id")
    } else if world
        .permits
        .iter()
        .any(|p| !ENCOUNTER_CLASSES.contains(&p.encounter_class))
    {
        Some("permit encounter_class unassigned")
    } else if world
        .permits
        .iter()
        .any(|p| !PERMIT_STATUSES.contains(&p.status))
    {
        Some("permit status unassigned")
    } else if !(s.created <= s.consumed && s.consumed <= s.minted && s.minted <= s.envelope) {
        Some("supply violates created <= consumed <= minted <= envelope")
    } else if u64::try_from(world.blockmon.len()).ok() != Some(s.created) {
        Some("blockmon count differs from supply.created")
    } else {
        None
    }
}

const fn rejected(reason: RejectReason) -> EffectsV0 {
    EffectsV0 {
        outcome: Outcome::Rejected,
        reject_reason: Some(reason),
        roll: None,
        creature: None,
    }
}

pub fn transition(
    world: &WorldV0,
    cmd: &CaptureCommand,
    ctx: &ContextV0,
    manifest: &ManifestV0,
) -> Transition {
    let mut reads = Vec::new();
    let reject = |reason, reads| Transition {
        next: world.clone(),
        effects: rejected(reason),
        reads,
        writes: Vec::new(),
    };

    if validity_violation(world, manifest).is_some() {
        return reject(RejectReason::InvalidState, reads);
    }
    reads.push(KeyRef {
        tag: Tag::Supply,
        key: ZERO32,
    });
    if ctx.epoch != world.supply.epoch {
        return reject(RejectReason::WrongEpoch, reads);
    }
    if manifest.assigned_round(ctx.position) != Some(u128::from(ctx.entropy_round)) {
        return reject(RejectReason::EntropyMismatch, reads);
    }
    reads.push(KeyRef {
        tag: Tag::Subject,
        key: cmd.subject,
    });
    if world.subjects.binary_search(&cmd.subject).is_err() {
        return reject(RejectReason::UnknownSubject, reads);
    }
    reads.push(KeyRef {
        tag: Tag::Encounter,
        key: cmd.permit_id,
    });
    let Ok(idx) = world
        .permits
        .binary_search_by(|p| p.permit_id.cmp(&cmd.permit_id))
    else {
        return reject(RejectReason::UnknownPermit, reads);
    };
    let permit = &world.permits[idx];
    if permit.status != STATUS_RESERVED {
        return reject(RejectReason::PermitNotReserved, reads);
    }
    if permit.subject != cmd.subject {
        return reject(RejectReason::WrongSubject, reads);
    }
    if ctx.position >= permit.expiry_position {
        return reject(RejectReason::PermitExpired, reads);
    }
    if world.supply.consumed >= world.supply.minted {
        return reject(RejectReason::NoCapability, reads);
    }
    let id = creature_id(&cmd.permit_id);
    reads.push(KeyRef {
        tag: Tag::Blockmon,
        key: id,
    });
    let Err(slot) = world.blockmon.binary_search_by(|b| b.creature_id.cmp(&id)) else {
        return reject(RejectReason::CreatureExists, reads);
    };

    execute(world, cmd, ctx, manifest, idx, slot, reads)
}

/// Every precondition has passed: the roll executes and the permit and one capability are
/// consumed whatever it yields. `idx` is the commanded permit, `slot` the creature's insertion
/// point.
fn execute(
    world: &WorldV0,
    cmd: &CaptureCommand,
    ctx: &ContextV0,
    manifest: &ManifestV0,
    idx: usize,
    slot: usize,
    reads: Vec<KeyRef>,
) -> Transition {
    let id = creature_id(&cmd.permit_id);
    let roll = roll(&capture_seed(
        &ctx.entropy_value,
        &cmd.permit_id,
        &manifest.hash(),
    ));
    let mut next = world.clone();
    next.permits[idx].status = STATUS_CONSUMED;
    next.supply.consumed += 1;
    let created = roll < u64::from(manifest.catch_rate_bp);
    if created {
        next.blockmon.insert(
            slot,
            BlockmonRecord {
                creature_id: id,
                owner: cmd.subject,
                origin_permit: cmd.permit_id,
            },
        );
        next.supply.created += 1;
    }
    let mut writes = vec![
        Write {
            at: KeyRef {
                tag: Tag::Encounter,
                key: cmd.permit_id,
            },
            old: Some(world.permits[idx].encode()),
            new: Some(next.permits[idx].encode()),
        },
        Write {
            at: KeyRef {
                tag: Tag::Supply,
                key: ZERO32,
            },
            old: Some(world.supply.encode()),
            new: Some(next.supply.encode()),
        },
    ];
    if created {
        writes.push(Write {
            at: KeyRef {
                tag: Tag::Blockmon,
                key: id,
            },
            old: None,
            new: Some(next.blockmon[slot].encode()),
        });
    }
    let effects = EffectsV0 {
        outcome: if created {
            Outcome::Created
        } else {
            Outcome::RollFailed
        },
        reject_reason: None,
        roll: Some(roll),
        creature: created.then_some(id),
    };
    Transition {
        next,
        effects,
        reads,
        writes,
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::t1::{PermitRecord, Supply};

    pub const SUBJECT: Hash32 = [0x10; 32];
    pub const OTHER: Hash32 = [0x20; 32];
    pub const PERMIT: Hash32 = [0x30; 32];

    pub fn fixture() -> (WorldV0, CaptureCommand, ContextV0, ManifestV0) {
        let world = WorldV0 {
            subjects: vec![SUBJECT, OTHER],
            blockmon: vec![],
            permits: vec![PermitRecord {
                permit_id: PERMIT,
                subject: SUBJECT,
                encounter_class: 1,
                expiry_position: 1000,
                status: STATUS_RESERVED,
            }],
            supply: Supply {
                epoch: 4,
                envelope: 10,
                minted: 5,
                consumed: 0,
                created: 0,
            },
        };
        let manifest = ManifestV0 {
            round_period: 32,
            entropy_safety_margin: 2,
            catch_rate_bp: 10_000,
        };
        let ctx = ContextV0 {
            position: 100,
            epoch: 4,
            entropy_round: 100 / 32 + 1 + 2,
            entropy_value: [7; 32],
        };
        (
            world,
            CaptureCommand {
                subject: SUBJECT,
                permit_id: PERMIT,
            },
            ctx,
            manifest,
        )
    }

    fn reason(t: &Transition) -> Option<RejectReason> {
        t.effects.reject_reason
    }

    #[test]
    fn success_consumes_and_creates() {
        let (w, cmd, ctx, m) = fixture();
        let t = transition(&w, &cmd, &ctx, &m);
        assert_eq!(t.effects.outcome, Outcome::Created);
        assert_eq!(t.next.permits[0].status, STATUS_CONSUMED);
        assert_eq!((t.next.supply.consumed, t.next.supply.created), (1, 1));
        let id = creature_id(&PERMIT);
        assert_eq!(t.effects.creature, Some(id));
        assert_eq!(
            t.next.blockmon,
            vec![BlockmonRecord {
                creature_id: id,
                owner: SUBJECT,
                origin_permit: PERMIT
            }]
        );
    }

    #[test]
    fn failed_roll_still_consumes() {
        let (w, cmd, ctx, mut m) = fixture();
        m.catch_rate_bp = 0;
        let t = transition(&w, &cmd, &ctx, &m);
        assert_eq!(t.effects.outcome, Outcome::RollFailed);
        assert!(t.effects.roll.is_some_and(|r| r < 10_000));
        assert_eq!(t.next.permits[0].status, STATUS_CONSUMED);
        assert_eq!((t.next.supply.consumed, t.next.supply.created), (1, 0));
        assert!(t.next.blockmon.is_empty());
    }

    #[test]
    fn roll_threshold_is_strict() {
        let (w, cmd, ctx, m) = fixture();
        for rate in (0..=10_000)
            .step_by(97)
            .chain([9_999, 10_000, 12_345, u32::MAX])
        {
            let m = ManifestV0 {
                catch_rate_bp: rate,
                ..m
            };
            let t = transition(&w, &cmd, &ctx, &m);
            let r = roll(&capture_seed(&ctx.entropy_value, &PERMIT, &m.hash()));
            assert_eq!(t.effects.roll, Some(r));
            let want = if r < u64::from(rate) {
                Outcome::Created
            } else {
                Outcome::RollFailed
            };
            assert_eq!(t.effects.outcome, want);
        }
        let never = ManifestV0 {
            catch_rate_bp: 0,
            ..m
        };
        assert_eq!(
            transition(&w, &cmd, &ctx, &never).effects.outcome,
            Outcome::RollFailed
        );
    }

    #[test]
    fn each_precondition_rejects_with_its_reason_and_returns_input() {
        let (w, cmd, ctx, m) = fixture();
        let cases: Vec<(RejectReason, WorldV0, CaptureCommand, ContextV0, ManifestV0)> = vec![
            (
                RejectReason::InvalidState,
                w.clone(),
                cmd,
                ctx,
                ManifestV0 {
                    round_period: 0,
                    ..m
                },
            ),
            (
                RejectReason::WrongEpoch,
                w.clone(),
                cmd,
                ContextV0 { epoch: 5, ..ctx },
                m,
            ),
            (
                RejectReason::EntropyMismatch,
                w.clone(),
                cmd,
                ContextV0 {
                    entropy_round: 7,
                    ..ctx
                },
                m,
            ),
            (
                RejectReason::UnknownSubject,
                w.clone(),
                CaptureCommand {
                    subject: [0x11; 32],
                    ..cmd
                },
                ctx,
                m,
            ),
            (
                RejectReason::UnknownPermit,
                w.clone(),
                CaptureCommand {
                    permit_id: [0x31; 32],
                    ..cmd
                },
                ctx,
                m,
            ),
            (
                RejectReason::WrongSubject,
                w.clone(),
                CaptureCommand {
                    subject: OTHER,
                    ..cmd
                },
                ctx,
                m,
            ),
            (
                RejectReason::PermitExpired,
                w.clone(),
                cmd,
                ContextV0 {
                    position: 1000,
                    entropy_round: 1000 / 32 + 3,
                    ..ctx
                },
                m,
            ),
        ];
        for (want, w, cmd, ctx, m) in cases {
            let t = transition(&w, &cmd, &ctx, &m);
            assert_eq!(reason(&t), Some(want));
            assert_eq!(t.next.encode(), w.encode());
            assert!(t.effects.is_well_formed());
        }
        let mut consumed = w.clone();
        consumed.permits[0].status = STATUS_CONSUMED;
        assert_eq!(
            reason(&transition(&consumed, &cmd, &ctx, &m)),
            Some(RejectReason::PermitNotReserved)
        );
        let mut exhausted = w;
        exhausted.supply.minted = 0;
        assert_eq!(
            reason(&transition(&exhausted, &cmd, &ctx, &m)),
            Some(RejectReason::NoCapability)
        );
    }

    #[test]
    fn a_round_beyond_u64_matches_no_entropy_round() {
        let (w, cmd, ctx, m) = fixture();
        let overflowing = ManifestV0 {
            round_period: 1,
            entropy_safety_margin: u64::MAX,
            ..m
        };
        let wrapped = ctx.position.wrapping_add(1).wrapping_add(u64::MAX);
        for entropy_round in [u64::MAX, wrapped, 0] {
            let c = ContextV0 {
                entropy_round,
                ..ctx
            };
            assert_eq!(
                reason(&transition(&w, &cmd, &c, &overflowing)),
                Some(RejectReason::EntropyMismatch)
            );
        }
        let at_limit = ManifestV0 {
            entropy_safety_margin: u64::MAX - 1 - ctx.position,
            ..overflowing
        };
        let c = ContextV0 {
            entropy_round: u64::MAX,
            ..ctx
        };
        assert_eq!(reason(&transition(&w, &cmd, &c, &at_limit)), None);
    }

    #[test]
    fn empty_domains_reject_by_absence() {
        let (w, cmd, ctx, m) = fixture();
        let no_subjects = WorldV0 {
            subjects: vec![],
            ..w.clone()
        };
        assert_eq!(
            reason(&transition(&no_subjects, &cmd, &ctx, &m)),
            Some(RejectReason::UnknownSubject)
        );
        let no_permits = WorldV0 {
            permits: vec![],
            ..w
        };
        assert_eq!(
            reason(&transition(&no_permits, &cmd, &ctx, &m)),
            Some(RejectReason::UnknownPermit)
        );
    }

    #[test]
    fn expiry_bound_is_exclusive() {
        let (w, cmd, ctx, m) = fixture();
        let at = ContextV0 {
            position: 999,
            entropy_round: 999 / 32 + 3,
            ..ctx
        };
        assert_eq!(reason(&transition(&w, &cmd, &at, &m)), None);
        let past = ContextV0 {
            position: 1000,
            entropy_round: 1000 / 32 + 3,
            ..ctx
        };
        assert_eq!(
            reason(&transition(&w, &cmd, &past, &m)),
            Some(RejectReason::PermitExpired)
        );
    }

    #[test]
    fn precondition_order_first_failure_wins() {
        let (w, cmd, ctx, m) = fixture();
        let mut bad = w.clone();
        bad.supply.created = 1;
        let everything = ContextV0 {
            epoch: 9,
            entropy_round: 0,
            position: 5000,
            ..ctx
        };
        assert_eq!(
            reason(&transition(&bad, &cmd, &everything, &m)),
            Some(RejectReason::InvalidState)
        );
        assert_eq!(
            reason(&transition(&w, &cmd, &everything, &m)),
            Some(RejectReason::WrongEpoch)
        );
        let e2 = ContextV0 {
            epoch: 4,
            ..everything
        };
        let stranger = CaptureCommand {
            subject: [0x11; 32],
            permit_id: [0x31; 32],
        };
        assert_eq!(
            reason(&transition(&w, &stranger, &e2, &m)),
            Some(RejectReason::EntropyMismatch)
        );
        let e3 = ContextV0 {
            entropy_round: 5000 / 32 + 3,
            ..e2
        };
        assert_eq!(
            reason(&transition(&w, &stranger, &e3, &m)),
            Some(RejectReason::UnknownSubject)
        );
        let wrong_owner_unknown = CaptureCommand {
            subject: OTHER,
            permit_id: [0x31; 32],
        };
        assert_eq!(
            reason(&transition(&w, &wrong_owner_unknown, &e3, &m)),
            Some(RejectReason::UnknownPermit)
        );
        let mut used = w.clone();
        used.permits[0].status = STATUS_CONSUMED;
        used.supply.minted = 0;
        used.supply.envelope = 0;
        let other = CaptureCommand {
            subject: OTHER,
            ..cmd
        };
        assert_eq!(
            reason(&transition(&used, &other, &e3, &m)),
            Some(RejectReason::PermitNotReserved)
        );
        let mut spent = w;
        spent.supply.minted = 0;
        assert_eq!(
            reason(&transition(&spent, &other, &e3, &m)),
            Some(RejectReason::WrongSubject)
        );
        assert_eq!(
            reason(&transition(&spent, &cmd, &e3, &m)),
            Some(RejectReason::PermitExpired)
        );
    }

    #[test]
    fn invalid_state_classes() {
        let (w, cmd, ctx, m) = fixture();
        let mut cases = Vec::new();
        let mut unsorted = w.clone();
        unsorted.subjects.reverse();
        cases.push(unsorted);
        let mut dup = w.clone();
        dup.subjects = vec![SUBJECT, SUBJECT];
        cases.push(dup);
        let mut status0 = w.clone();
        status0.permits[0].status = 0;
        cases.push(status0);
        let mut class2 = w.clone();
        class2.permits[0].encounter_class = 2;
        cases.push(class2);
        let mut over = w.clone();
        over.supply.minted = 11;
        cases.push(over);
        let mut elsewhere = w.clone();
        elsewhere.permits.push(PermitRecord {
            permit_id: [0x31; 32],
            status: 0,
            ..w.permits[0].clone()
        });
        cases.push(elsewhere);
        let mut repeated = w.clone();
        let record = BlockmonRecord {
            creature_id: [1; 32],
            owner: SUBJECT,
            origin_permit: PERMIT,
        };
        repeated.blockmon = vec![record.clone(), record.clone()];
        repeated.supply.consumed = 1;
        repeated.supply.created = 1;
        cases.push(repeated.clone());
        repeated.supply.consumed = 2;
        repeated.supply.created = 2;
        cases.push(repeated);
        let mut count = w;
        count.blockmon.push(record);
        cases.push(count);
        for bad in cases {
            assert_eq!(
                reason(&transition(&bad, &cmd, &ctx, &m)),
                Some(RejectReason::InvalidState)
            );
        }
    }

    /// A valid world whose blockmon domain already holds `creature_id(PERMIT)`.
    pub fn creature_present() -> (WorldV0, CaptureCommand, ContextV0, ManifestV0) {
        let (mut w, cmd, ctx, m) = fixture();
        w.blockmon.push(BlockmonRecord {
            creature_id: creature_id(&PERMIT),
            owner: OTHER,
            origin_permit: [0x40; 32],
        });
        w.supply.consumed = 1;
        w.supply.created = 1;
        (w, cmd, ctx, m)
    }

    #[test]
    fn existing_creature_key_rejects_before_the_roll() {
        let (w, cmd, ctx, m) = creature_present();
        assert_eq!(validity_violation(&w, &m), None);
        for rate in [0, 10_000] {
            let m = ManifestV0 {
                catch_rate_bp: rate,
                ..m
            };
            let t = transition(&w, &cmd, &ctx, &m);
            assert_eq!(reason(&t), Some(RejectReason::CreatureExists));
            assert_eq!(t.effects.roll, None);
            assert_eq!(t.next.encode(), w.encode());
            assert!(t.writes.is_empty());
            assert_eq!(
                t.reads.last(),
                Some(&KeyRef {
                    tag: Tag::Blockmon,
                    key: creature_id(&PERMIT)
                })
            );
        }
        let mut exhausted = w;
        exhausted.supply.minted = 1;
        exhausted.supply.envelope = 1;
        assert_eq!(validity_violation(&exhausted, &m), None);
        assert_eq!(
            reason(&transition(&exhausted, &cmd, &ctx, &m)),
            Some(RejectReason::NoCapability)
        );
    }

    #[test]
    fn writes_name_exactly_the_touched_keys() {
        let (w, cmd, ctx, m) = fixture();
        let created = transition(&w, &cmd, &ctx, &m);
        let keys: Vec<Tag> = created.writes.iter().map(|x| x.at.tag).collect();
        assert_eq!(keys, [Tag::Encounter, Tag::Supply, Tag::Blockmon]);
        assert_eq!(created.writes[2].old, None);
        let failed = transition(
            &w,
            &cmd,
            &ctx,
            &ManifestV0 {
                catch_rate_bp: 0,
                ..m
            },
        );
        let keys: Vec<Tag> = failed.writes.iter().map(|x| x.at.tag).collect();
        assert_eq!(keys, [Tag::Encounter, Tag::Supply]);
    }

    #[test]
    fn replay_of_an_executed_command_is_rejected() {
        let (w, cmd, ctx, m) = fixture();
        let t = transition(&w, &cmd, &ctx, &m);
        let again = transition(&t.next, &cmd, &ctx, &m);
        assert_eq!(reason(&again), Some(RejectReason::PermitNotReserved));
        assert_eq!(again.next, t.next);
    }
}
