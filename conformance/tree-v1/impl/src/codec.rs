//! CE §2 primitive decoding, strict and exact-consume.

use core::fmt;

use crate::hash::Hash32;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DecodeError {
    Truncated {
        needed: usize,
        remaining: usize,
    },
    TrailingBytes {
        extra: usize,
    },
    UnassignedEnum {
        field: &'static str,
        discriminant: u8,
    },
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Truncated { needed, remaining } => {
                write!(f, "truncated: needed {needed} bytes, {remaining} remaining")
            }
            Self::TrailingBytes { extra } => write!(f, "trailing bytes: {extra} unconsumed"),
            Self::UnassignedEnum {
                field,
                discriminant,
            } => {
                write!(
                    f,
                    "unassigned enum discriminant {discriminant} for field `{field}`"
                )
            }
        }
    }
}

pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub const fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        let remaining = self.buf.len() - self.pos;
        if n > remaining {
            return Err(DecodeError::Truncated {
                needed: n,
                remaining,
            });
        }
        let slice = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    pub fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }

    pub fn u64(&mut self) -> Result<u64, DecodeError> {
        let mut wide = [0u8; 8];
        wide.copy_from_slice(self.take(8)?);
        Ok(u64::from_be_bytes(wide))
    }

    pub fn hash32(&mut self) -> Result<Hash32, DecodeError> {
        let mut out = [0u8; 32];
        out.copy_from_slice(self.take(32)?);
        Ok(out)
    }

    /// CE §2: "Decoding a top-level value MUST consume the input exactly."
    pub const fn finish(self) -> Result<(), DecodeError> {
        let extra = self.buf.len() - self.pos;
        match extra {
            0 => Ok(()),
            extra => Err(DecodeError::TrailingBytes { extra }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DecodeError, Reader};

    #[test]
    fn big_endian_widths() {
        let mut r = Reader::new(&[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
        assert_eq!(r.u64(), Ok(0x0102_0304_0506_0708));
        assert_eq!(r.finish(), Ok(()));
    }

    #[test]
    fn truncation_and_trailing_are_distinct_rejections() {
        let mut short = Reader::new(&[0x00; 7]);
        assert_eq!(
            short.u64(),
            Err(DecodeError::Truncated {
                needed: 8,
                remaining: 7
            })
        );

        let mut long = Reader::new(&[0x00; 9]);
        assert_eq!(long.u64(), Ok(0));
        assert_eq!(long.finish(), Err(DecodeError::TrailingBytes { extra: 1 }));
    }
}
