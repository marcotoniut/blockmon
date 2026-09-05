//! CE §7 tag table and the CE §6 record schemas the tree authenticates.

use crate::codec::{DecodeError, Reader};
use crate::hash::Hash32;

/// CE §7: "Tags are assigned; `0` is not a valid tag."
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Tag {
    Subject,
    Blockmon,
    Encounter,
    Supply,
}

impl Tag {
    pub const ALL: [Self; 4] = [Self::Subject, Self::Blockmon, Self::Encounter, Self::Supply];

    pub const fn discriminant(self) -> u8 {
        match self {
            Self::Subject => 1,
            Self::Blockmon => 2,
            Self::Encounter => 3,
            Self::Supply => 4,
        }
    }

    pub const fn from_discriminant(value: u8) -> Option<Self> {
        match value {
            1 => Some(Self::Subject),
            2 => Some(Self::Blockmon),
            3 => Some(Self::Encounter),
            4 => Some(Self::Supply),
            _ => None,
        }
    }

    pub const fn domain_name(self) -> &'static str {
        match self {
            Self::Subject => "subject",
            Self::Blockmon => "blockmon",
            Self::Encounter => "encounter",
            Self::Supply => "supply",
        }
    }
}

/// CE §6: `enum { COMMON = 1 }`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EncounterClass {
    Common,
}

impl EncounterClass {
    const fn discriminant(self) -> u8 {
        match self {
            Self::Common => 1,
        }
    }

    fn decode(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
        match r.u8()? {
            1 => Ok(Self::Common),
            discriminant => Err(DecodeError::UnassignedEnum {
                field: "encounter_class",
                discriminant,
            }),
        }
    }
}

/// CE §6: `enum { RESERVED = 1, CONSUMED = 2 }`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PermitStatus {
    Reserved,
    Consumed,
}

impl PermitStatus {
    const fn discriminant(self) -> u8 {
        match self {
            Self::Reserved => 1,
            Self::Consumed => 2,
        }
    }

    fn decode(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
        match r.u8()? {
            1 => Ok(Self::Reserved),
            2 => Ok(Self::Consumed),
            discriminant => Err(DecodeError::UnassignedEnum {
                field: "status",
                discriminant,
            }),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct BlockmonRecord {
    pub creature_id: Hash32,
    pub owner: Hash32,
    pub origin_permit: Hash32,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct PermitRecord {
    pub permit_id: Hash32,
    pub subject: Hash32,
    pub encounter_class: EncounterClass,
    pub expiry_position: u64,
    pub status: PermitStatus,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Supply {
    pub epoch: u64,
    pub envelope: u64,
    pub minted: u64,
    pub consumed: u64,
    pub created: u64,
}

impl Supply {
    /// CE §6 `INVALID_STATE`, minus the cross-domain `extant == created` clause, which no
    /// single record can express.
    pub const fn accounting_chain_holds(&self) -> bool {
        self.created <= self.consumed
            && self.consumed <= self.minted
            && self.minted <= self.envelope
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Record {
    Subject,
    Blockmon(BlockmonRecord),
    Encounter(PermitRecord),
    Supply(Supply),
}

impl Record {
    /// CE §2 strict exact-consume decoding at the declared width for `tag`.
    pub fn decode(tag: Tag, bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let record = match tag {
            Tag::Subject => Self::Subject,
            Tag::Blockmon => Self::Blockmon(BlockmonRecord {
                creature_id: r.hash32()?,
                owner: r.hash32()?,
                origin_permit: r.hash32()?,
            }),
            Tag::Encounter => Self::Encounter(PermitRecord {
                permit_id: r.hash32()?,
                subject: r.hash32()?,
                encounter_class: EncounterClass::decode(&mut r)?,
                expiry_position: r.u64()?,
                status: PermitStatus::decode(&mut r)?,
            }),
            Tag::Supply => Self::Supply(Supply {
                epoch: r.u64()?,
                envelope: r.u64()?,
                minted: r.u64()?,
                consumed: r.u64()?,
                created: r.u64()?,
            }),
        };
        r.finish()?;
        Ok(record)
    }

    /// CE §2 record row: fields concatenated in specification-declared order.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        match *self {
            Self::Subject => {}
            Self::Blockmon(b) => {
                out.extend_from_slice(&b.creature_id);
                out.extend_from_slice(&b.owner);
                out.extend_from_slice(&b.origin_permit);
            }
            Self::Encounter(p) => {
                out.extend_from_slice(&p.permit_id);
                out.extend_from_slice(&p.subject);
                out.push(p.encounter_class.discriminant());
                out.extend_from_slice(&p.expiry_position.to_be_bytes());
                out.push(p.status.discriminant());
            }
            Self::Supply(s) => {
                for field in [s.epoch, s.envelope, s.minted, s.consumed, s.created] {
                    out.extend_from_slice(&field.to_be_bytes());
                }
            }
        }
        out
    }

    pub const fn tag(&self) -> Tag {
        match *self {
            Self::Subject => Tag::Subject,
            Self::Blockmon(_) => Tag::Blockmon,
            Self::Encounter(_) => Tag::Encounter,
            Self::Supply(_) => Tag::Supply,
        }
    }

    /// CE §7 Key column: the field a record names as its own identifier, where it has one.
    pub const fn identifier(&self) -> Option<Hash32> {
        match *self {
            Self::Blockmon(b) => Some(b.creature_id),
            Self::Encounter(p) => Some(p.permit_id),
            Self::Subject | Self::Supply(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DecodeError, Record, Tag};

    const fn widths() -> [(Tag, usize); 4] {
        [
            (Tag::Subject, 0),
            (Tag::Blockmon, 96),
            (Tag::Encounter, 74),
            (Tag::Supply, 40),
        ]
    }

    #[test]
    fn declared_widths_round_trip_and_are_exact() {
        for (tag, width) in widths() {
            let mut bytes = vec![0u8; width];
            if matches!(tag, Tag::Encounter) {
                bytes[64] = 1;
                bytes[73] = 1;
            }
            let record = Record::decode(tag, &bytes).expect("declared width decodes");
            assert_eq!(record.encode(), bytes);
            assert_eq!(record.tag(), tag);

            let mut short = bytes.clone();
            if short.pop().is_some() {
                assert!(matches!(
                    Record::decode(tag, &short),
                    Err(DecodeError::Truncated { .. })
                ));
            }

            let mut long = bytes;
            long.push(0);
            assert_eq!(
                Record::decode(tag, &long),
                Err(DecodeError::TrailingBytes { extra: 1 }),
                "{tag:?} accepted a wider record"
            );
        }
    }

    #[test]
    fn enum_zero_and_unassigned_discriminants_are_rejected() {
        let mut permit = vec![0u8; 74];
        permit[73] = 1;
        assert_eq!(
            Record::decode(Tag::Encounter, &permit),
            Err(DecodeError::UnassignedEnum {
                field: "encounter_class",
                discriminant: 0
            })
        );
        permit[64] = 2;
        assert_eq!(
            Record::decode(Tag::Encounter, &permit),
            Err(DecodeError::UnassignedEnum {
                field: "encounter_class",
                discriminant: 2
            })
        );
        permit[64] = 1;
        for bad in [0u8, 3, 255] {
            permit[73] = bad;
            assert_eq!(
                Record::decode(Tag::Encounter, &permit),
                Err(DecodeError::UnassignedEnum {
                    field: "status",
                    discriminant: bad
                })
            );
        }
    }

    #[test]
    fn tag_discriminants_are_one_through_four_and_zero_is_invalid() {
        assert_eq!(Tag::from_discriminant(0), None);
        for tag in Tag::ALL {
            assert_eq!(Tag::from_discriminant(tag.discriminant()), Some(tag));
        }
        for unassigned in [0u8, 5, 6, 255] {
            assert_eq!(Tag::from_discriminant(unassigned), None, "{unassigned}");
        }
    }
}
