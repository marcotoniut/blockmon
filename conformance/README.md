# conformance: G0a golden vectors

`docs/architecture/canonical-encoding.md` is the authority. This corpus
proves that every observable boundary yields a single canonical byte form and
one domain-separated hash for protocol-visible values:

```
semantic value → canonical bytes → protocol hash → commitment / transcript
```

## Contents

```
gen/                Odin generator (uses protocol/canonical); bare run emits
                    the seed corpus, `expansion` subcommand the seeded tier
check.py            independent Python checker; re-derives every value in both
                    corpora from the spec document, shares no code with the
                    Odin side
vectors/            g0a-vectors.json (constitutional seed) and
                    g0a-expansion.json (deterministic seeded expansion)
cross-target.sh     emits both corpora per target and compares byte-for-byte
fuzz/               G0b property/fuzz harness for the Transition 1 kernel
                    (raw generators, model oracle, canonical-bytes equality;
                    reproduce any failure from seed + phase + case + step)
```

## Running

```
just g0a                        # regenerate both corpora + independent check
bash conformance/cross-target.sh  # native + linux_{arm64,amd64,riscv64} via docker
```

Two tiers. The seed corpus is the small constitutional one: 47 vectors plus 4
distinctness pairs covering integer/bool/bytes/string/optional/sequence
boundaries, ambiguity and domain boundary-shift pairs, transcript ordering,
the promoted Slice B transcript objects, kernel-backed Transition 1 vectors
(success, roll-failed, rejected), and rejection vectors.

The expansion tier (~1000 vectors, fixed literal seed in the generator, no OS
randomness) covers the same observable boundaries at volume: integers at and
around every width boundary, length-prefix and multi-byte UTF-8 boundaries,
nested and empty optionals/sequences, seeded records/transcripts,
domain-separated hashes, Transition 1 vectors across every outcome and
rejection path, and rejection vectors derived systematically from valid
encodings (truncations, trailing bytes, non-canonical forms). Every
Transition 1 vector in either tier is asserted against the protocol.md §10
conservation identities by the generator before emission and re-derived
independently by check.py: byte agreement alone cannot pass. The semantic
input→output step is deliberately left to G0c; the 10⁶ property/fuzz
hardening is G0b.

`check.py` and `gen` are currently written by the same party. G0c's
independent implementation (different engineer, no reference-source reuse)
supersedes this check, not replaces it.

Vectors are regenerated per ProtocolManifest version and archived, never
edited in place.