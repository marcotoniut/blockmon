//! Transition 1 objects and derivations (canonical-encoding.md §6).

use crate::encoding::{DecodeError, Decoder, Encoder, Hash32, protocol_hash, protocol_hash_parts};

pub const DOMAIN_MANIFEST: &str = "blockmon/manifest/v0";
pub const DOMAIN_CAPTURE_CMD: &str = "blockmon/capture-cmd/v0";
/// Under `blockmon/world/v1`; `blockmon/transition/v0` is the archived flat-root derivation.
pub const DOMAIN_TRANSITION: &str = "blockmon/transition/v1";
pub const DOMAIN_CREATURE_ID: &str = "blockmon/creature-id/v0";
pub const DOMAIN_CAPTURE_ROLL: &str = "blockmon/capture-roll/v0";

pub const ENCOUNTER_CLASS_COMMON: u8 = 1;
pub const ENCOUNTER_CLASSES: &[u8] = &[ENCOUNTER_CLASS_COMMON];
pub const STATUS_RESERVED: u8 = 1;
pub const STATUS_CONSUMED: u8 = 2;
pub const PERMIT_STATUSES: &[u8] = &[STATUS_RESERVED, STATUS_CONSUMED];

pub const ROLL_MODULUS: u64 = 10_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockmonRecord {
    pub creature_id: Hash32,
    pub owner: Hash32,
    pub origin_permit: Hash32,
}

/// Enum fields hold the raw wire discriminant so that unassigned values are representable
/// kernel input, which `INVALID_STATE` must then reject.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermitRecord {
    pub permit_id: Hash32,
    pub subject: Hash32,
    pub encounter_class: u8,
    pub expiry_position: u64,
    pub status: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Supply {
    pub epoch: u64,
    pub envelope: u64,
    pub minted: u64,
    pub consumed: u64,
    pub created: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorldV0 {
    pub subjects: Vec<Hash32>,
    pub blockmon: Vec<BlockmonRecord>,
    pub permits: Vec<PermitRecord>,
    pub supply: Supply,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ManifestV0 {
    pub round_period: u64,
    pub entropy_safety_margin: u64,
    pub catch_rate_bp: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CaptureCommand {
    pub subject: Hash32,
    pub permit_id: Hash32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContextV0 {
    pub position: u64,
    pub epoch: u64,
    pub entropy_round: u64,
    pub entropy_value: Hash32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    UnknownSubject = 1,
    UnknownPermit = 2,
    PermitNotReserved = 3,
    WrongSubject = 4,
    PermitExpired = 5,
    NoCapability = 6,
    EntropyMismatch = 7,
    WrongEpoch = 8,
    InvalidState = 9,
    CreatureExists = 10,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Created = 1,
    RollFailed = 2,
    Rejected = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EffectsV0 {
    pub outcome: Outcome,
    pub reject_reason: Option<RejectReason>,
    pub roll: Option<u64>,
    pub creature: Option<Hash32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptV0 {
    pub command_hash: Hash32,
    pub prev_root: Hash32,
    pub next_root: Hash32,
    pub effects: EffectsV0,
}

impl BlockmonRecord {
    pub fn encode_into(&self, e: &mut Encoder) {
        e.hash32(&self.creature_id)
            .hash32(&self.owner)
            .hash32(&self.origin_permit);
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut e = Encoder::new();
        self.encode_into(&mut e);
        e.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut d = Decoder::new(bytes);
        let r = Self::decode_from(&mut d)?;
        d.finish()?;
        Ok(r)
    }

    fn decode_from(d: &mut Decoder<'_>) -> Result<Self, DecodeError> {
        Ok(Self {
            creature_id: d.hash32()?,
            owner: d.hash32()?,
            origin_permit: d.hash32()?,
        })
    }
}

impl PermitRecord {
    pub fn encode_into(&self, e: &mut Encoder) {
        e.hash32(&self.permit_id)
            .hash32(&self.subject)
            .u8(self.encounter_class)
            .u64(self.expiry_position)
            .u8(self.status);
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut e = Encoder::new();
        self.encode_into(&mut e);
        e.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut d = Decoder::new(bytes);
        let r = Self::decode_from(&mut d, true)?;
        d.finish()?;
        Ok(r)
    }

    /// `strict` refuses an unassigned discriminant; the §6 state reader keeps the one held.
    fn decode_from(d: &mut Decoder<'_>, strict: bool) -> Result<Self, DecodeError> {
        let enumerated = |d: &mut Decoder<'_>, assigned| {
            if strict { d.enum_u8(assigned) } else { d.u8() }
        };
        Ok(Self {
            permit_id: d.hash32()?,
            subject: d.hash32()?,
            encounter_class: enumerated(d, ENCOUNTER_CLASSES)?,
            expiry_position: d.u64()?,
            status: enumerated(d, PERMIT_STATUSES)?,
        })
    }
}

impl Supply {
    pub fn encode_into(&self, e: &mut Encoder) {
        e.u64(self.epoch)
            .u64(self.envelope)
            .u64(self.minted)
            .u64(self.consumed)
            .u64(self.created);
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut e = Encoder::new();
        self.encode_into(&mut e);
        e.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut d = Decoder::new(bytes);
        let r = Self::decode_from(&mut d)?;
        d.finish()?;
        Ok(r)
    }

    fn decode_from(d: &mut Decoder<'_>) -> Result<Self, DecodeError> {
        Ok(Self {
            epoch: d.u64()?,
            envelope: d.u64()?,
            minted: d.u64()?,
            consumed: d.u64()?,
            created: d.u64()?,
        })
    }
}

impl WorldV0 {
    pub fn encode(&self) -> Vec<u8> {
        let mut e = Encoder::new();
        e.seq(&self.subjects, |e, s| {
            e.hash32(s);
        });
        e.seq(&self.blockmon, |e, b| b.encode_into(e));
        e.seq(&self.permits, |e, p| p.encode_into(e));
        self.supply.encode_into(&mut e);
        e.finish()
    }

    /// The strict §2 decoder, for wire objects: an unassigned discriminant or a listing that is
    /// not in §6 canonical form is refused.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let w = Self::decode_listing(bytes, true)?;
        if w.is_canonically_ordered() {
            Ok(w)
        } else {
            Err(DecodeError::NonCanonicalOrder)
        }
    }

    /// §2 structure only: listing order, repeats and every discriminant are kept as given.
    pub fn read_listing(bytes: &[u8]) -> Result<Self, DecodeError> {
        Self::decode_listing(bytes, false)
    }

    fn decode_listing(bytes: &[u8], strict: bool) -> Result<Self, DecodeError> {
        let mut d = Decoder::new(bytes);
        let w = Self {
            subjects: d.seq(Decoder::hash32)?,
            blockmon: d.seq(BlockmonRecord::decode_from)?,
            permits: d.seq(|d| PermitRecord::decode_from(d, strict))?,
            supply: Supply::decode_from(&mut d)?,
        };
        d.finish()?;
        Ok(w)
    }

    pub fn is_canonically_ordered(&self) -> bool {
        strictly_ascending(&self.subjects, |k| k)
            && strictly_ascending(&self.blockmon, |b| &b.creature_id)
            && strictly_ascending(&self.permits, |p| &p.permit_id)
    }
}

pub fn strictly_ascending<T>(items: &[T], key: impl Fn(&T) -> &Hash32) -> bool {
    items.windows(2).all(|w| key(&w[0]) < key(&w[1]))
}

impl ManifestV0 {
    pub fn encode(&self) -> Vec<u8> {
        Encoder::new()
            .u64(self.round_period)
            .u64(self.entropy_safety_margin)
            .u32(self.catch_rate_bp)
            .finish()
    }

    pub fn hash(&self) -> Hash32 {
        protocol_hash(DOMAIN_MANIFEST, &self.encode())
    }

    /// `assigned_round(p) = p / round_period + 1 + entropy_safety_margin`, in exact integer
    /// arithmetic. `None` for `round_period = 0`.
    pub fn assigned_round(&self, position: u64) -> Option<u128> {
        let q = position.checked_div(self.round_period)?;
        Some(u128::from(q) + 1 + u128::from(self.entropy_safety_margin))
    }

    #[cfg(test)]
    pub fn reveal_position(&self, round: u128) -> u128 {
        round * u128::from(self.round_period)
    }
}

impl CaptureCommand {
    pub fn encode(&self) -> Vec<u8> {
        Encoder::new()
            .hash32(&self.subject)
            .hash32(&self.permit_id)
            .finish()
    }

    pub fn hash(&self) -> Hash32 {
        protocol_hash(DOMAIN_CAPTURE_CMD, &self.encode())
    }
}

impl EffectsV0 {
    pub fn encode_into(&self, e: &mut Encoder) {
        e.u8(self.outcome as u8)
            .optional(self.reject_reason, |e, r| {
                e.u8(r as u8);
            })
            .optional(self.roll, |e, r| {
                e.u64(r);
            })
            .optional(self.creature, |e, c| {
                e.hash32(&c);
            });
    }

    /// The presence rules stated beside each `EffectsV0` field.
    pub const fn is_well_formed(&self) -> bool {
        let rejected = matches!(self.outcome, Outcome::Rejected);
        let created = matches!(self.outcome, Outcome::Created);
        self.reject_reason.is_some() == rejected
            && self.roll.is_some() != rejected
            && self.creature.is_some() == created
    }
}

impl TranscriptV0 {
    pub fn encode(&self) -> Vec<u8> {
        let mut e = Encoder::new();
        e.hash32(&self.command_hash)
            .hash32(&self.prev_root)
            .hash32(&self.next_root);
        self.effects.encode_into(&mut e);
        e.finish()
    }

    pub fn hash(&self) -> Hash32 {
        protocol_hash(DOMAIN_TRANSITION, &self.encode())
    }
}

pub fn creature_id(permit_id: &Hash32) -> Hash32 {
    protocol_hash(DOMAIN_CREATURE_ID, permit_id)
}

pub fn capture_seed(entropy_value: &Hash32, permit_id: &Hash32, manifest_hash: &Hash32) -> Hash32 {
    protocol_hash_parts(
        DOMAIN_CAPTURE_ROLL,
        &[entropy_value, permit_id, manifest_hash],
    )
}

pub fn roll(seed: &Hash32) -> u64 {
    let mut head = [0u8; 8];
    head.copy_from_slice(&seed[..8]);
    u64::from_be_bytes(head) % ROLL_MODULUS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoding::{ZERO32, is_valid_domain};
    use sha2::{Digest, Sha256};

    #[test]
    fn every_t1_domain_is_well_formed() {
        for d in [
            DOMAIN_MANIFEST,
            DOMAIN_CAPTURE_CMD,
            DOMAIN_TRANSITION,
            DOMAIN_CREATURE_ID,
            DOMAIN_CAPTURE_ROLL,
        ] {
            assert!(is_valid_domain(d), "{d}");
        }
    }

    #[test]
    fn record_widths_follow_declared_field_order() {
        let p = PermitRecord {
            permit_id: [1; 32],
            subject: [2; 32],
            encounter_class: 1,
            expiry_position: 0x0102,
            status: 2,
        };
        let b = p.encode();
        assert_eq!(b.len(), 32 + 32 + 1 + 8 + 1);
        assert_eq!(&b[64..], &[1, 0, 0, 0, 0, 0, 0, 1, 2, 2]);
        assert_eq!(PermitRecord::decode(&b), Ok(p));
        let m = ManifestV0 {
            round_period: 1,
            entropy_safety_margin: 2,
            catch_rate_bp: 3,
        };
        assert_eq!(
            m.encode(),
            [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 3]
        );
        let s = Supply {
            epoch: 1,
            envelope: 2,
            minted: 3,
            consumed: 4,
            created: 5,
        };
        assert_eq!(s.encode().len(), 40);
        assert_eq!(Supply::decode(&s.encode()), Ok(s));
    }

    #[test]
    fn permit_decoding_rejects_enum_zero_and_unassigned() {
        let mut b = PermitRecord {
            permit_id: ZERO32,
            subject: ZERO32,
            encounter_class: 1,
            expiry_position: 0,
            status: 1,
        }
        .encode();
        b[73] = 0;
        assert_eq!(
            PermitRecord::decode(&b),
            Err(DecodeError::UnassignedEnum(0))
        );
        b[73] = 3;
        assert_eq!(
            PermitRecord::decode(&b),
            Err(DecodeError::UnassignedEnum(3))
        );
        b[73] = 1;
        b[64] = 2;
        assert_eq!(
            PermitRecord::decode(&b),
            Err(DecodeError::UnassignedEnum(2))
        );
    }

    #[test]
    fn effects_encoding_and_presence_rules() {
        let rejected = EffectsV0 {
            outcome: Outcome::Rejected,
            reject_reason: Some(RejectReason::PermitExpired),
            roll: None,
            creature: None,
        };
        let mut e = Encoder::new();
        rejected.encode_into(&mut e);
        assert_eq!(e.finish(), [3, 1, 5, 0, 0]);
        assert!(rejected.is_well_formed());
        let failed = EffectsV0 {
            outcome: Outcome::RollFailed,
            reject_reason: None,
            roll: Some(258),
            creature: None,
        };
        let mut e = Encoder::new();
        failed.encode_into(&mut e);
        assert_eq!(e.finish(), [2, 0, 1, 0, 0, 0, 0, 0, 0, 1, 2, 0]);
        assert!(failed.is_well_formed());
        assert!(
            !EffectsV0 {
                creature: Some(ZERO32),
                ..failed
            }
            .is_well_formed()
        );
    }

    #[test]
    fn transcript_is_three_hashes_then_effects() {
        let t = TranscriptV0 {
            command_hash: [1; 32],
            prev_root: [2; 32],
            next_root: [3; 32],
            effects: EffectsV0 {
                outcome: Outcome::Created,
                reject_reason: None,
                roll: Some(1),
                creature: Some([4; 32]),
            },
        };
        let b = t.encode();
        assert_eq!(b.len(), 96 + 1 + 1 + 9 + 33);
        assert_eq!(&b[..32], &[1; 32]);
        assert_eq!(&b[32..64], &[2; 32]);
        assert_eq!(&b[64..96], &[3; 32]);
        assert_eq!(&b[96..99], &[1, 0, 1]);
        assert_eq!(t.hash(), protocol_hash("blockmon/transition/v1", &b));
        assert_ne!(t.hash(), protocol_hash("blockmon/transition/v0", &b));
        let c = CaptureCommand {
            subject: [5; 32],
            permit_id: [6; 32],
        };
        let mut cat = vec![5u8; 32];
        cat.extend_from_slice(&[6; 32]);
        assert_eq!(c.hash(), protocol_hash("blockmon/capture-cmd/v0", &cat));
    }

    #[test]
    fn derivations_follow_the_written_preimages() {
        let pid = [0x42; 32];
        let mut pre = vec![23u8];
        pre.extend_from_slice(DOMAIN_CREATURE_ID.as_bytes());
        pre.extend_from_slice(&pid);
        assert_eq!(creature_id(&pid), <Hash32>::from(Sha256::digest(&pre)));

        let (ev, mh) = ([1; 32], [3; 32]);
        let mut cat = Vec::new();
        cat.extend_from_slice(&ev);
        cat.extend_from_slice(&pid);
        cat.extend_from_slice(&mh);
        assert_eq!(
            capture_seed(&ev, &pid, &mh),
            protocol_hash(DOMAIN_CAPTURE_ROLL, &cat)
        );

        let mut seed = [0xff; 32];
        seed[..8].copy_from_slice(&123_456_789u64.to_be_bytes());
        assert_eq!(roll(&seed), 123_456_789 % 10_000);
    }

    #[test]
    fn assigned_round_and_reveal_strictly_after_position() {
        let m = ManifestV0 {
            round_period: 32,
            entropy_safety_margin: 2,
            catch_rate_bp: 0,
        };
        assert_eq!(m.assigned_round(0), Some(3));
        assert_eq!(m.assigned_round(31), Some(3));
        assert_eq!(m.assigned_round(32), Some(4));
        for p in [0u64, 1, 31, 32, 33, 1000, u64::MAX] {
            let r = m.assigned_round(p).unwrap_or_default();
            assert!(m.reveal_position(r) > u128::from(p));
        }
        let zero = ManifestV0 {
            round_period: 0,
            ..m
        };
        assert_eq!(zero.assigned_round(5), None);
        let wide = ManifestV0 {
            round_period: 1,
            entropy_safety_margin: u64::MAX,
            catch_rate_bp: 0,
        };
        assert!(
            wide.assigned_round(u64::MAX)
                .is_some_and(|r| r > u128::from(u64::MAX))
        );
    }
}
