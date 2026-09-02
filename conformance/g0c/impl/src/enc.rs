//! Canonical encoding, strict decoding, and the domain-separated protocol hash,
//! implemented solely from spec/canonical-encoding.md.

use sha2::{Digest, Sha256};

pub type Hash32 = [u8; 32];

// ---------- encoding ----------

pub fn put_u8(out: &mut Vec<u8>, v: u8) {
    out.push(v);
}
pub fn put_u16(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_be_bytes());
}
pub fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}
pub fn put_u64(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_be_bytes());
}
pub fn put_bool(out: &mut Vec<u8>, v: bool) {
    out.push(u8::from(v));
}
// spec fixes length prefixes at u32; checker inputs are far below u32::MAX bytes
#[expect(clippy::cast_possible_truncation)]
pub fn put_bytes(out: &mut Vec<u8>, v: &[u8]) {
    put_u32(out, v.len() as u32);
    out.extend_from_slice(v);
}
pub fn put_string(out: &mut Vec<u8>, v: &str) {
    put_bytes(out, v.as_bytes());
}
pub fn put_hash32(out: &mut Vec<u8>, v: &Hash32) {
    out.extend_from_slice(v);
}
pub fn put_optional<T, F: Fn(&mut Vec<u8>, &T)>(out: &mut Vec<u8>, v: Option<&T>, f: F) {
    match v {
        None => out.push(0x00),
        Some(inner) => {
            out.push(0x01);
            f(out, inner);
        }
    }
}
// spec fixes length prefixes at u32; checker inputs are far below u32::MAX items
#[expect(clippy::cast_possible_truncation)]
pub fn put_seq<T, F: Fn(&mut Vec<u8>, &T)>(out: &mut Vec<u8>, v: &[T], f: F) {
    put_u32(out, v.len() as u32);
    for item in v {
        f(out, item);
    }
}

// ---------- protocol hash ----------

pub fn protocol_hash(domain: &str, payload: &[u8]) -> Hash32 {
    let d = domain.as_bytes();
    assert!(
        !d.is_empty()
            && d.len() <= 255
            && d.iter()
                .all(|b| (0x21..=0x7e).contains(b) && !b.is_ascii_uppercase()),
        "invalid domain: {domain}"
    );
    let mut h = Sha256::new();
    // asserted above: domain length <= 255
    #[expect(clippy::cast_possible_truncation)]
    h.update([d.len() as u8]);
    h.update(d);
    h.update(payload);
    h.finalize().into()
}

// ---------- strict decoding ----------

#[derive(Debug)]
pub struct DecodeError(pub String);

pub type DResult<T> = Result<T, DecodeError>;

fn err<T>(msg: &str) -> DResult<T> {
    Err(DecodeError(msg.to_string()))
}

pub struct Dec<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Dec<'a> {
    pub const fn new(buf: &'a [u8]) -> Self {
        Dec { buf, pos: 0 }
    }

    fn take(&mut self, n: usize) -> DResult<&'a [u8]> {
        if self.buf.len() - self.pos < n {
            return err("truncated input");
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    fn take_array<const N: usize>(&mut self) -> DResult<[u8; N]> {
        self.take(N)?
            .try_into()
            .map_err(|_| DecodeError("truncated input".to_string()))
    }

    pub fn finish(&self) -> DResult<()> {
        if self.pos == self.buf.len() {
            Ok(())
        } else {
            err("trailing bytes")
        }
    }

    pub fn u8(&mut self) -> DResult<u8> {
        Ok(self.take(1)?[0])
    }
    pub fn u16(&mut self) -> DResult<u16> {
        Ok(u16::from_be_bytes(self.take_array()?))
    }
    pub fn u32(&mut self) -> DResult<u32> {
        Ok(u32::from_be_bytes(self.take_array()?))
    }
    pub fn u64(&mut self) -> DResult<u64> {
        Ok(u64::from_be_bytes(self.take_array()?))
    }
    pub fn bool(&mut self) -> DResult<bool> {
        match self.u8()? {
            0x00 => Ok(false),
            0x01 => Ok(true),
            _ => err("non-canonical bool"),
        }
    }
    pub fn bytes(&mut self) -> DResult<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    pub fn string(&mut self) -> DResult<&'a str> {
        let raw = self.bytes()?;
        std::str::from_utf8(raw).map_or_else(|_| err("invalid UTF-8"), Ok)
    }
    pub fn hash32(&mut self) -> DResult<Hash32> {
        self.take_array()
    }
    pub fn enum_of(&mut self, allowed: &[u8]) -> DResult<u8> {
        let d = self.u8()?;
        if allowed.contains(&d) {
            Ok(d)
        } else {
            err("unassigned enum discriminant")
        }
    }
    pub fn optional<T>(&mut self, f: impl FnOnce(&mut Self) -> DResult<T>) -> DResult<Option<T>> {
        match self.u8()? {
            0x00 => Ok(None),
            0x01 => Ok(Some(f(self)?)),
            _ => err("invalid optional flag"),
        }
    }
    pub fn seq<T>(&mut self, mut f: impl FnMut(&mut Self) -> DResult<T>) -> DResult<Vec<T>> {
        let n = self.u32()?;
        let mut out = Vec::new();
        for _ in 0..n {
            out.push(f(&mut *self)?);
        }
        Ok(out)
    }
}

/// Decode a top-level value; input must be consumed exactly.
pub fn decode_top<T>(buf: &[u8], f: impl FnOnce(&mut Dec) -> DResult<T>) -> DResult<T> {
    let mut d = Dec::new(buf);
    let v = f(&mut d)?;
    d.finish()?;
    Ok(v)
}
