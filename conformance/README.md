# conformance: G0a golden vectors

`docs/architecture/canonical-encoding.md` is the authority. This corpus
proves that every observable boundary yields a single canonical byte form and
one domain-separated hash for protocol-visible values:

```
semantic value → canonical bytes → protocol hash → commitment / transcript
```

## Evidence tiers

Five evidence tiers, distinct by design.

The v0 seed and expansion corpora are historical. They prove the flat-root
Transition 1 semantics pinned by `blockmon/world/v0`, are retained
byte-identically, and are not produced by the current kernel, which commits
`blockmon/world/v1`. `ARCHIVE.sha256` pins their digests; changing one
requires changing the pin in the same commit. `check.py` re-derives every
value from the spec on every run.

The v1 tiers are current. The tree tiers pin the authenticated construction,
hand-derived first and generated second, while the Transition 1 v1 tier pins
what the kernel commits today. The v1 tree expansion tier covers domain
occupancy from empty to 257 keys, the bit-order boundaries where two keys first
diverge, inclusion and absence proofs at varied occupancy, and one bounded
update per case for all three transitions a key can undergo, in every domain
that admits them. Its rejections cover both classes, including two rejected
updates that no accepted case can demonstrate. The generator asserts
equivalence between the bounded path and a full derivation before emission, and
the cleanroom crate re-derives every value from the spec. `gen/` stays in the tree because it produced
the archive, but no gate runs it: a generator that can no longer reproduce the
archive must not be able to overwrite it.

## Contents

```
gen/                Odin generator for the archived v0 corpora; bare run emits
                    the seed corpus, `expansion` subcommand the seeded tier
gen-tree/           Odin generator for the v1 tree expansion tier
check.py            independent Python checker; re-derives every value in both
                    v0 corpora from the spec document, shares no code with the
                    Odin side
vectors/            g0a-vectors.json and g0a-expansion.json (archived v0, with
                    ARCHIVE.sha256 pinning their digests), g0a-tree-v1.json and
                    g0a-tree-v1-expansion.json (v1 tree), g0a-t1-v1.json
                    (Transition 1 under blockmon/world/v1)
tree/               Odin checker for the hand-derived v1 tree tier
t1-v1/              Odin checker for the Transition 1 v1 tier; the hand-derived
                    tier, the full derivation and the bounded update path must
                    agree on every scenario
g0c/                Rust cleanroom for the v0 kernel, built from the spec
tree-v1/            Rust cleanroom for the v1 tree, built from the spec, run as
                    a standing gate
cross-target.sh     emits the v1 tree expansion tier per target; every leg must
                    equal the native run and the committed vectors byte-for-byte
fuzz/               G0b property/fuzz harness for the Transition 1 kernel
                    (raw generators, model oracle, canonical-bytes equality,
                    commitment tracking; reproduce any failure from
                    seed + phase + case + step)
```

## Running

```
just g0a-archive                # archived v0 corpora: digests + independent check
just tree-v1                    # v1 tree: hand-derived tier, then regenerate the expansion
just t1-v1                      # Transition 1 under world/v1, three oracles
just g0b                        # 10^6 singles + 2*10^4 sequences, 500 tracked steps per phase
just g0b 12166583181037 1000000 20000 20000   # CI depth: 20000 tracked steps per phase
just g0c                        # Rust cleanroom over the archived v0 corpora
just tree-v1-rust               # Rust cleanroom over both v1 tree tiers
bash conformance/cross-target.sh  # v1 expansion tier: native + linux_{arm64,amd64,riscv64} via docker
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