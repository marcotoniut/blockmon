# Blockmon

AR creature-collection game where players physically discover, capture, battle, breed and trade creatures ("Blockmon") whose existence, ownership and scarcity are constitutionally guaranteed rather than administratively asserted.

This is a **design-first** repo: the system is specified independently of blockchain, proof system or language before any implementation. Key guarantees: ownership provable against settled state, scarcity bounded by a constitutional schedule, correct transitions independently verifiable, and the world recoverable even if all operators disappear.

## Docs

- `docs/architecture/architecture.md`: the frozen architecture and invariants (start here)
- `docs/architecture/protocol.md`, `battle-channel.md`, `canonical-encoding.md`, `trust-and-economy.md`, `verification.md`, `prototype-and-technology.md`: layers
- `protocol/canonical/`: canonical encoding implementation; `conformance/`: G0a golden vectors + independent checker
- `learning/`: slate for learning materials and course implementations

## Scaffolding

With Nix (canonical, pinned via `flake.lock`):

```
nix develop    # odin, foundry, python3, ruff, shellcheck, lefthook, just, docker client
```

Without Nix: `brew install just odin foundry python3 ruff shellcheck lefthook`. Versions then drift;
the flake is the recorded toolchain. SDL3 (`brew install sdl3`) is needed only
for the graphics course under `learning/` and is deliberately not in the Nix
shell. The Solidity compiler is owned by `prototype/slice-b/contracts/foundry.toml`,
fetched once by forge. Docker's daemon (colima/Desktop) stays outside Nix; only
the CLI is provided.

Key tasks (see `justfile`):

```
just learn3d   # run the Pikuma 3D graphics course implementation (Odin + SDL3)
just           # list all tasks
```

## References

- Pikuma, "Learn Computer Graphics Programming": <https://courses.pikuma.com/courses/take/learn-computer-graphics-programming>