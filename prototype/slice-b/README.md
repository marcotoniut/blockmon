# Slice B: battle-channel E2E

This is a barebones end-to-end proof of the integration boundaries defined in
`docs/architecture/prototype-and-technology.md` §2 and `docs/architecture/battle-channel.md`.
Everything here is deliberately hard-coded and test-specific; the only reusable artefacts are
the protocol fixtures.

## Layout

```
contracts/          Foundry project: BattleSettlement.sol + negative-path tests
channel/            participant adapter: transport, session, transcript, checkpoint,
                    read-only chain access (chain.odin)
probe/              single-process Odin protocol probe (not a game client)
player-a/           participant A: A's ephemeral seeds and role wiring, nothing else
player-b/           participant B: B's ephemeral seeds and role wiring, nothing else
e2e.sh              full round trip against a local anvil
battle.sh           dual-process run: two participant processes, one battle
fixtures/           deterministic probe vectors (feed G0a)
```

## Running

Requires `odin`, `foundry` (`brew install foundry`), and `python3`.

```
just slice-b-test        # contract tests: signatures, replay, supersession, timeout
just slice-b-e2e         # anvil → deploy → anchor keys → channel → settle → assert
just slice-b-probe       # probe alone; prints the channel JSON
just slice-b-battle-e2e  # dual-process battle, automated
just slice-b-battle      # dual-process battle, manual two-terminal flow
```

## What the E2E proves

1. Both participants derive the same battle session secret off-chain (X25519 + HKDF, `core:crypto`); purpose keys are domain-separated.
2. Ephemeral battle public keys are anchored on-chain under wallet authorisations bound to battle id + ruleset + expiry.
3. A hash-chained, Ed25519-signed exchange runs locally and cross-verifies.
4. Cooperative settlement is one compact dual-authorised checkpoint; the recorded on-chain outcome, including the settled state commitment, equals the deterministic local result.
5. Duplicate settlement is rejected; timeout settlement resolves to the default outcome after deadline + response window (chain time warped via anvil).

## Dual-process battle run

`e2e.sh` simulates both participants inside one process. `battle.sh` runs the same
battle as two independent OS processes, so the secret boundary and each
participant's own verification have to survive a process boundary rather than a
function boundary.

```
                       anvil (127.0.0.1:8546)
                   BattleSettlement (thin verifier)
                     ^                          ^
                     |  read-only eth_call      |
         player-a (own process)          player-b (own process)
                     \                          /
                      \-- 127.0.0.1:47301 TCP -/

                battle.json: joining instruction, checked against the chain
```

Manual flow, three terminals:

```
Terminal 0:  just slice-b-battle    # chain + one battle; prints the next two commands
Terminal 1:  just slice-b-player-a
Terminal 2:  just slice-b-player-b
```

Terminal 0 settles once both participants have produced channel evidence; each
then reads the recorded outcome from the chain and checks it against its own
state.

```
PLAYER B
battle:     0xd1dad3b06e5b19545cddfde2d1c23035d70c5e6cc5a34636e689036f298b91c2
ruleset:    0xc0f25cea684bf88ee11713b710cce4cb89c3c45ca859783e008720bb9b514bd1
anchored:   ruleset, participants and both keys read from 127.0.0.1:8546
joined:     anchored keys for b are this process's own
transport:  dialling 127.0.0.1:47301
peer:       a authenticated, ed 0x79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664
session:    established, check 0xc643d659
op 1:       accepted move:ember
op 2:       sent     move:splash
head:       0xda70977c135a85fccbf1138e60064f6221d6c6727120dcd26b4887042de30853
checkpoint: seq 2 result A_WINS state 0x6b8582431d814055a8e4b67529281c93cad96f2a2f196d4db7a1ef64ddd0d721
authorised: dual-signed by b and a
settled:    A_WINS (seq 2), as recorded on chain
```

`just slice-b-battle-e2e` is the same run with the harness launching both
participants, capturing each one's stdout and stderr separately, and asserting.

### What it adds

1. **Secrets survive a process boundary.** Each participant is a separate program
   holding only its own ephemeral seeds; `channel/` is shared protocol code with
   no key material, and the harness checks that at the source. The session secret
   never crosses the wire and is never printed: each side publishes an
   HKDF-derived witness of it and the harness asserts the two agree.
2. **Reading is not delegated** (`architecture.md` §21). Signing stays outside
   Odin, but each participant reads the anchored battle and the settled outcome
   from the chain itself. Nothing the harness writes to disk is trusted for
   either. Verified by tampering: a descriptor with the wrong ruleset, the wrong
   counterparty key or the wrong participant wallet is rejected against the chain
   before the battle starts.
3. **Two processes converge on the promoted vectors.** Transcript head, state
   commitment, checkpoint hash, result and both Ed25519 checkpoint signatures come
   out byte-identical to the single-process probe's G0a values.

### Evidence

`build/battle-run/` holds `battle.json`, `session-{a,b}.json` (each side's
independently derived values) and `wire-{a,b}.log` (every frame either side sent
or received, in full). The harness asserts that what A sent is byte-identical to
what B received and vice versa, so the entire information flow across the boundary
is on disk and readable. All of it hashes the same on every run, manual or
automated, because the key material, moves and ruleset are pinned.

### Failure bounds

A participant gives the transport handshake 120s (human-scale, since the manual
flow starts the second terminal by hand), each in-band frame 10s, and settlement
30s of chain polls. A closed connection and a silent counterparty report as
different failures. The automated harness independently bounds channel evidence at
45s and participant exit at 30s, kills both processes and prints their captured
output; a participant that dies before producing evidence fails the run at once.

### What it does not prove

Production multiplayer networking; peer discovery; hostile-network resilience;
reconnect or resume; NAT traversal; production wallet UX; mental-poker
correctness or any hidden-information battle semantics; production chain
topology. It is also not evidence for G0c: both participants share
`protocol/canonical`, so this is one implementation running twice, not two.

## Stand-in decisions (deliberate, documented)

- The contract stands in for the canonical constitutional layer (`battle-channel.md` §1). Per-battle L1 transactions are a slice artefact, not the production settlement shape.
- The EVM cannot verify Ed25519 cheaply, so on-chain settlement authorisation uses wallet secp256k1 co-signatures over the checkpoint digest; the Ed25519 channel evidence is bound through `stateCommitment`. In production the canonical layer verifies the ephemeral signatures directly.
- Wallet keys are anvil's deterministic accounts, signed via `cast`; Odin contains no chain cryptography (`architecture.md` §21).
- Key seeds and battle entropy are fixed test vectors, so every run emits byte-identical fixtures (`fixtures/probe-vectors.json`).
- Protocol bytes (op encoding, hashes, state commitment) come from `protocol/canonical`, the implementation of `docs/architecture/canonical-encoding.md`; the probe's transcript values are identical to the promoted vectors in `conformance/vectors/g0a-vectors.json`.
- The contract test harness declares its own 5-function `Vm` interface instead of pulling forge-std; no submodules, no dependencies.
- `channel/` is shared by both participants and the probe so the key schedule, transcript construction and checkpoint representation exist once rather than being forked per program. It is slice scaffolding, not the start of a client framework, and holds no key material.
- The dual-process run uses its own chain port (8546) so it can run beside `e2e.sh`.
- Its transport is direct localhost TCP with length-prefixed frames and four frame kinds (hello / op / checkpoint signature / done): the smallest mechanism that makes the process boundary real. A relay would have added a process without adding evidence, and which side listens is descriptor data, not a protocol asymmetry.
- The settled state commitment is recorded on chain because without it a participant could confirm only that someone won, not that the state it derived is the state that settled.
- `channel/chain.odin` is a read-only path, not an RPC client: one hard-coded JSON-RPC request shape, three pinned selectors, fixed-width word extraction. The selectors are constants because Ethereum Keccak-256 stays out of Odin (`architecture.md` §21), so `battle.sh` asserts each of them against `cast sig` by name.