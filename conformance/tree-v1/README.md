# conformance/tree-v1: standing v1 authenticated-tree checker

Independent Rust implementation of the v1 authenticated state tree, derived
from `canonical-encoding.md` §7 and `protocol.md` §§1-2 in a source-isolated
session without access to the Odin reference, generators, or earlier
implementations. The structure was arrived at independently, which is part of
the evidence. Promoted unchanged except for path plumbing.

Both tiers run: 16 hand-derived constitutional checks comparing 1884 recorded
values (including every sibling of every proof), and the generated expansion
tier with 9 sections and 9610 values. Then 19 adversarial checks verifying
that neither corpus describes a wider language than the spec permits, plus a
corpus-language scan that walks the JSON independently of the typed harnesses.
28 unit tests assert the construction against the prose rather than any
corpus.

Two isolated passes produced this. The first derived the construction from
prose alone, reproduced every value, and reported 14 specification findings (3
computation-affecting), which became amendments. The second ran against the
corrected spec, reproduced both tiers without inferring semantics from either
corpus, and reported 10 further findings, 4 of which corrected text the
amendments had introduced. This crate is the second pass's implementation. One
mismatch occurred across its gates, classified as a harness error rather than
a derivation error: it asserted a per-domain count against the supply domain,
which the singleton key caps at one entry. No semantic rule changed.

The delta this note tracked is closed. Identifier binding is now enforced at
the proof boundary and in domain state. The expansion tier exercises it via a
positive control, and the adversarial assertion that recorded the original
finding now asserts the rule.

## Running

```
just tree-v1-rust
```

or from `impl/`:

```
cargo run --release -- ../../vectors/g0a-tree-v1.json ../../vectors/g0a-tree-v1-expansion.json
```

Exit 0 and a non-zero mismatch count of zero on success. With no arguments the
crate defaults to the repository's corpus paths.
