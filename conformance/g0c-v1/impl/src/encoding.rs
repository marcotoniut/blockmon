//! Canonical encoding (canonical-encoding.md §2) and the protocol hash (§3).

use sha2::{Digest, Sha256};

pub type Hash32 = [u8; 32];

pub const ZERO32: Hash32 = [0; 32];

#[derive(Debug, Default)]
pub struct Encoder {
    buf: Vec<u8>,
}

impl Encoder {
    pub const fn new() -> Self {
        Self { buf: Vec::new() }
    }

    pub fn u8(&mut self, v: u8) -> &mut Self {
        self.buf.push(v);
        self
    }

    #[cfg(test)]
    pub fn u16(&mut self, v: u16) -> &mut Self {
        self.buf.extend_from_slice(&v.to_be_bytes());
        self
    }

    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_be_bytes());
        self
    }

    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.buf.extend_from_slice(&v.to_be_bytes());
        self
    }

    #[cfg(test)]
    pub fn bool(&mut self, v: bool) -> &mut Self {
        self.u8(u8::from(v))
    }

    #[cfg(test)]
    pub fn bytes(&mut self, v: &[u8]) -> &mut Self {
        self.length(v.len());
        self.buf.extend_from_slice(v);
        self
    }

    #[cfg(test)]
    pub fn string(&mut self, v: &str) -> &mut Self {
        self.bytes(v.as_bytes())
    }

    pub fn hash32(&mut self, v: &Hash32) -> &mut Self {
        self.buf.extend_from_slice(v);
        self
    }

    pub fn optional<T>(&mut self, v: Option<T>, f: impl FnOnce(&mut Self, T)) -> &mut Self {
        match v {
            None => {
                self.u8(0x00);
            }
            Some(x) => {
                self.u8(0x01);
                f(self, x);
            }
        }
        self
    }

    pub fn seq<T>(&mut self, items: &[T], f: impl Fn(&mut Self, &T)) -> &mut Self {
        self.length(items.len());
        for item in items {
            f(self, item);
        }
        self
    }

    fn length(&mut self, n: usize) {
        let n = u32::try_from(n).expect("length prefix exceeds u32");
        self.u32(n);
    }

    pub fn finish(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.buf)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "no T1 object holds a bool, optional or string to decode"
    )
)]
pub enum DecodeError {
    Truncated,
    BadBool(u8),
    BadOptionalFlag(u8),
    UnassignedEnum(u8),
    InvalidUtf8,
    LengthExceedsInput,
    TrailingBytes(usize),
    NonCanonicalOrder,
}

pub struct Decoder<'a> {
    input: &'a [u8],
    pos: usize,
}

impl<'a> Decoder<'a> {
    pub const fn new(input: &'a [u8]) -> Self {
        Self { input, pos: 0 }
    }

    const fn remaining(&self) -> usize {
        self.input.len() - self.pos
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        if n > self.remaining() {
            return Err(DecodeError::Truncated);
        }
        let out = &self.input[self.pos..self.pos + n];
        self.pos += n;
        Ok(out)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], DecodeError> {
        let mut out = [0u8; N];
        out.copy_from_slice(self.take(N)?);
        Ok(out)
    }

    pub fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.array::<1>()?[0])
    }

    #[cfg(test)]
    pub fn u16(&mut self) -> Result<u16, DecodeError> {
        Ok(u16::from_be_bytes(self.array()?))
    }

    pub fn u32(&mut self) -> Result<u32, DecodeError> {
        Ok(u32::from_be_bytes(self.array()?))
    }

    pub fn u64(&mut self) -> Result<u64, DecodeError> {
        Ok(u64::from_be_bytes(self.array()?))
    }

    #[cfg(test)]
    pub fn bool(&mut self) -> Result<bool, DecodeError> {
        match self.u8()? {
            0x00 => Ok(false),
            0x01 => Ok(true),
            b => Err(DecodeError::BadBool(b)),
        }
    }

    fn length(&mut self) -> Result<usize, DecodeError> {
        let n = usize::try_from(self.u32()?).map_err(|_| DecodeError::LengthExceedsInput)?;
        if n > self.remaining() {
            return Err(DecodeError::LengthExceedsInput);
        }
        Ok(n)
    }

    #[cfg(test)]
    pub fn bytes(&mut self) -> Result<Vec<u8>, DecodeError> {
        let n = self.length()?;
        Ok(self.take(n)?.to_vec())
    }

    #[cfg(test)]
    pub fn string(&mut self) -> Result<String, DecodeError> {
        String::from_utf8(self.bytes()?).map_err(|_| DecodeError::InvalidUtf8)
    }

    pub fn hash32(&mut self) -> Result<Hash32, DecodeError> {
        self.array()
    }

    pub fn enum_u8(&mut self, assigned: &[u8]) -> Result<u8, DecodeError> {
        let d = self.u8()?;
        if assigned.contains(&d) {
            Ok(d)
        } else {
            Err(DecodeError::UnassignedEnum(d))
        }
    }

    #[cfg(test)]
    pub fn optional<T>(
        &mut self,
        f: impl FnOnce(&mut Self) -> Result<T, DecodeError>,
    ) -> Result<Option<T>, DecodeError> {
        match self.u8()? {
            0x00 => Ok(None),
            0x01 => f(self).map(Some),
            b => Err(DecodeError::BadOptionalFlag(b)),
        }
    }

    pub fn seq<T>(
        &mut self,
        f: impl Fn(&mut Self) -> Result<T, DecodeError>,
    ) -> Result<Vec<T>, DecodeError> {
        let n = self.length()?;
        (0..n).map(|_| f(self)).collect()
    }

    /// Top-level values must consume the input exactly (§2).
    pub const fn finish(&self) -> Result<(), DecodeError> {
        match self.remaining() {
            0 => Ok(()),
            n => Err(DecodeError::TrailingBytes(n)),
        }
    }
}

/// §3: 1-255 bytes of printable ASCII, lowercase, ending in `/v<decimal>`.
pub fn is_valid_domain(domain: &str) -> bool {
    let b = domain.as_bytes();
    if b.is_empty() || b.len() > 255 {
        return false;
    }
    if !b
        .iter()
        .all(|c| (0x21..=0x7e).contains(c) && !c.is_ascii_uppercase())
    {
        return false;
    }
    domain.rfind("/v").is_some_and(|i| {
        let digits = &domain[i + 2..];
        !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit())
    })
}

pub fn protocol_hash(domain: &str, payload: &[u8]) -> Hash32 {
    protocol_hash_parts(domain, &[payload])
}

/// `ProtocolHash(domain, p1 ‖ p2 ‖ ...)`, without materialising the concatenation.
pub fn protocol_hash_parts(domain: &str, parts: &[&[u8]]) -> Hash32 {
    assert!(
        is_valid_domain(domain),
        "invalid protocol hash domain {domain:?}"
    );
    framed_hash(domain.as_bytes(), parts)
}

#[cfg(test)]
thread_local! {
    pub static HASHES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// `SHA-256(u8(len(domain)) ‖ domain ‖ payload)` with no check on the domain's shape.
fn framed_hash(domain: &[u8], parts: &[&[u8]]) -> Hash32 {
    #[cfg(test)]
    HASHES.with(|c| c.set(c.get() + 1));
    let len = u8::try_from(domain.len()).expect("domain is at most 255 bytes");
    let mut h = Sha256::new();
    h.update([len]);
    h.update(domain);
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

pub fn hex32(h: &Hash32) -> String {
    format!("0x{}", hex::encode(h))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sha256(b: &[u8]) -> Hash32 {
        Sha256::digest(b).into()
    }

    #[test]
    fn integers_are_fixed_width_big_endian() {
        let b = Encoder::new()
            .u8(0xab)
            .u16(0x0102)
            .u32(0x0304_0506)
            .u64(0x0708_090a_0b0c_0d0e)
            .finish();
        assert_eq!(b, [0xab, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]);
        assert_eq!(Encoder::new().u64(0).finish(), [0; 8]);
        assert_eq!(Encoder::new().u64(u64::MAX).finish(), [0xff; 8]);
    }

    #[test]
    fn bool_and_optional_and_seq_shapes() {
        assert_eq!(Encoder::new().bool(false).bool(true).finish(), [0, 1]);
        let mut e = Encoder::new();
        e.optional(None::<u8>, |e, v| {
            e.u8(v);
        });
        assert_eq!(e.finish(), [0]);
        e.seq(&[] as &[u8], |e, v| {
            e.u8(*v);
        });
        assert_eq!(e.finish(), [0, 0, 0, 0]);
        e.optional(Some(()), |e, ()| {
            e.seq(&[] as &[u8], |e, v| {
                e.u8(*v);
            });
        });
        assert_eq!(e.finish(), [1, 0, 0, 0, 0]);
    }

    #[test]
    fn length_prefix_separates_adjacent_strings() {
        let a = Encoder::new().string("A").string("BC").finish();
        let b = Encoder::new().string("AB").string("C").finish();
        assert_ne!(a, b);
        assert_eq!(a, [0, 0, 0, 1, b'A', 0, 0, 0, 2, b'B', b'C']);
    }

    #[test]
    fn strings_are_not_normalised() {
        let composed = Encoder::new().string("\u{e9}").finish();
        let decomposed = Encoder::new().string("e\u{301}").finish();
        assert_ne!(composed, decomposed);
        assert_eq!(composed, [0, 0, 0, 2, 0xc3, 0xa9]);
    }

    #[test]
    fn decoder_rejects_every_non_canonical_form() {
        assert_eq!(Decoder::new(&[2]).bool(), Err(DecodeError::BadBool(2)));
        assert_eq!(
            Decoder::new(&[0]).enum_u8(&[1, 2]),
            Err(DecodeError::UnassignedEnum(0))
        );
        assert_eq!(
            Decoder::new(&[0, 0, 0, 1, 0xff]).string(),
            Err(DecodeError::InvalidUtf8)
        );
        assert_eq!(
            Decoder::new(&[0, 0, 0, 5, 1]).bytes(),
            Err(DecodeError::LengthExceedsInput)
        );
        assert_eq!(
            Decoder::new(&[0, 0, 0, 9]).seq(Decoder::u8),
            Err(DecodeError::LengthExceedsInput)
        );
        assert_eq!(
            Decoder::new(&[2]).optional(Decoder::u8),
            Err(DecodeError::BadOptionalFlag(2))
        );
        assert_eq!(Decoder::new(&[0; 31]).hash32(), Err(DecodeError::Truncated));
        let mut d = Decoder::new(&[1, 2]);
        assert_eq!(d.u8(), Ok(1));
        assert_eq!(d.finish(), Err(DecodeError::TrailingBytes(1)));
    }

    #[test]
    fn decoder_round_trips() {
        let b = Encoder::new()
            .bool(true)
            .bytes(b"xy")
            .optional(Some(7u64), |e, v| {
                e.u64(v);
            })
            .seq(&[1u16, 2], |e, v| {
                e.u16(*v);
            })
            .finish();
        let mut d = Decoder::new(&b);
        assert_eq!(d.bool(), Ok(true));
        assert_eq!(d.bytes(), Ok(b"xy".to_vec()));
        assert_eq!(d.optional(Decoder::u64), Ok(Some(7)));
        assert_eq!(d.seq(Decoder::u16), Ok(vec![1, 2]));
        assert_eq!(d.finish(), Ok(()));
    }

    #[test]
    fn protocol_hash_is_length_prefixed_domain_then_payload() {
        let mut pre = vec![14u8];
        pre.extend_from_slice(b"blockmon/aa/v0");
        pre.extend_from_slice(b"bb");
        assert_eq!(protocol_hash("blockmon/aa/v0", b"bb"), sha256(&pre));
        assert!(is_valid_domain("blockmon/aa/v1") && is_valid_domain("blockmon/aa/v10"));
        assert_ne!(
            protocol_hash("blockmon/aa/v1", b"0b"),
            protocol_hash("blockmon/aa/v10", b"b")
        );
        assert_eq!(
            [b"blockmon/aa/v1".as_slice(), b"0b"].concat(),
            [b"blockmon/aa/v10".as_slice(), b"b"].concat()
        );
    }

    #[test]
    fn sha256_matches_fips_180_4() {
        assert_eq!(
            hex::encode(sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn domain_rules() {
        assert!(is_valid_domain("blockmon/world/v1"));
        assert!(is_valid_domain("blockmon/smt-leaf/v0"));
        assert!(!is_valid_domain(""));
        assert!(!is_valid_domain("blockmon/World/v1"));
        assert!(!is_valid_domain("blockmon/world"));
        assert!(!is_valid_domain("blockmon/world/v"));
        assert!(!is_valid_domain("blockmon/world/v1a"));
        assert!(!is_valid_domain("blockmon world/v1"));
        assert!(!is_valid_domain(&format!("{}/v1", "a".repeat(253))));
        assert!(is_valid_domain(&format!("{}/v1", "a".repeat(252))));
    }
}
