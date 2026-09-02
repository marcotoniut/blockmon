# conformance: G0c independent implementation

Cleanroom Rust implementation of canonical encoding, protocol hashing and
Transition 1, built in isolated passes against the written spec. Pass 1
(2026-09-01) derived everything from `canonical-encoding.md` and
`protocol.md` alone, passed the 51-check seed corpus, and surfaced four spec
gaps. One gap (reject-reason discriminants) was only resolvable from a
vector. The spec was amended; pass 2 re-derived Transition 1 semantics from
the amended prose under the same isolation regime, extending the checker to
the expansion corpus. Two further amendment rounds (INVALID_STATE
valid-input definition, then the extant == created clause) were each
re-derived the same way.

Result: PASS, 1187/1187 across both corpora (51 seed, 1136 expansion; all
nine reject reasons exercised, every representable branch of the
INVALID_STATE guard vector-tested, §10 conservation identities asserted on
every computed transition). All constants and predicates derive from spec
text; no value remains vector-derived. `REPORT.md` records all sessions
verbatim.

## Running

```
just g0c
```

or from `impl/`: `cargo run --quiet -- ../../vectors/g0a-vectors.json
../../vectors/g0a-expansion.json`. Exit 0 and `RESULT: PASS` on success.