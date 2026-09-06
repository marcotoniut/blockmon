//! CE §3 protocol hash and the CE §7 domain strings.

use sha2::{Digest, Sha256};

pub type Hash32 = [u8; 32];

pub const SMT_LEAF: &str = "blockmon/smt-leaf/v0";
pub const SMT_NODE: &str = "blockmon/smt-node/v0";
pub const SMT_EMPTY: &str = "blockmon/smt-empty/v0";
pub const WORLD_V1: &str = "blockmon/world/v1";

/// `ProtocolHash(domain, payload) = SHA-256( u8(len(domain)) ‖ domain ‖ payload )`.
pub fn protocol_hash(domain: &str, payload: &[u8]) -> Hash32 {
    let domain = domain.as_bytes();
    let len = u8::try_from(domain.len()).expect("CE §3: a domain is 1-255 bytes");
    let mut hasher = Sha256::new();
    hasher.update([len]);
    hasher.update(domain);
    hasher.update(payload);
    hasher.finalize().into()
}

/// CE §3: 1-255 bytes of printable ASCII (0x21-0x7e), lowercase, ending in `/v<decimal>`.
pub fn domain_is_well_formed(domain: &str) -> bool {
    let bytes = domain.as_bytes();
    if bytes.is_empty() || bytes.len() > 255 {
        return false;
    }
    if !bytes
        .iter()
        .all(|b| (0x21..=0x7e).contains(b) && !b.is_ascii_uppercase())
    {
        return false;
    }
    let Some(marker) = domain.rfind("/v") else {
        return false;
    };
    let suffix = &bytes[marker + 2..];
    !suffix.is_empty() && suffix.iter().all(u8::is_ascii_digit)
}

#[cfg(test)]
mod tests {
    use super::{SMT_EMPTY, SMT_LEAF, SMT_NODE, WORLD_V1, domain_is_well_formed, protocol_hash};

    #[test]
    fn ce3_domain_grammar_holds_for_every_tree_domain() {
        for domain in [SMT_LEAF, SMT_NODE, SMT_EMPTY, WORLD_V1] {
            assert!(domain_is_well_formed(domain), "{domain}");
        }
        assert!(!domain_is_well_formed(""));
        assert!(!domain_is_well_formed("Blockmon/smt-node/v0"));
        assert!(!domain_is_well_formed("blockmon/smt-node/v"));
        assert!(!domain_is_well_formed("blockmon/smt node/v0"));
    }

    /// CE §3: the length prefix keeps (domain, payload) framing unambiguous.
    #[test]
    fn boundary_shift_between_domain_and_payload_is_distinguished() {
        assert_ne!(
            protocol_hash("blockmon/aa/v0", b"bb"),
            protocol_hash("blockmon/aa/v0b", b"b")
        );
    }

    /// Known answers taken from the platform `shasum -a 256`, not from any implementation
    /// of this protocol: SHA-256(0x01 ‖ "a") and SHA-256(0x15 ‖ "blockmon/smt-empty/v0").
    #[test]
    fn known_answer_for_the_construction() {
        assert_eq!(
            hex::encode(protocol_hash("a", b"")),
            "e3254ea61c09ead5a01d3bf07e946a561c6c2cd1c46b8ca1bfa8729d26a7d09f"
        );
        assert_eq!(
            hex::encode(protocol_hash(SMT_EMPTY, b"")),
            "30dd52c02f7f8386045858e25e846ae0cc1b9f514f0a37916e24fb8c92d510de"
        );
    }
}
