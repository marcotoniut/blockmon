# conformance/g0c-v1: Transition 1 under world/v1, independent implementation

Independent Rust implementation of Transition 1, checked against both Transition 1 v1 tiers. Isolated sessions derived it from `canonical-encoding.md` and `protocol.md` alone. Each pass gave a fresh session the specification as amended so far, both tiers, and its own earlier crate and reports. The crate is promoted unchanged except for path plumbing. `REPORT.md` records every session verbatim, and the last report's register lists what remains open. The sessions' analysis scripts and run logs are not kept, since the reports quote what they found.

## Running

```
just g0c-v1
```

or from `impl/`: `cargo run --release -- ../../vectors/g0a-t1-v1.json ../../vectors/g0a-t1-v1-expansion.json`.
Exit 0 and `RESULT: PASS` on success.
