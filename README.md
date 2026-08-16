# Blockmon

AR creature-collection game where players physically discover, capture, battle, breed and trade creatures ("Blockmon") whose existence, ownership and scarcity are constitutionally guaranteed rather than administratively asserted.

This is a **design-first** repo: the system is specified independently of blockchain, proof system or language before any implementation. Key guarantees: ownership provable against settled state, scarcity bounded by a constitutional schedule, correct transitions independently verifiable, and the world recoverable even if all operators disappear.

## Docs

- `docs/architecture/architecture.md` — the frozen architecture and invariants (start here)
- `docs/architecture/protocol.md`, `trust-and-economy.md`, `verification.md`, `prototype-and-technology.md` — layers
- `docs/engineering/` — investigations
- `learning/` — slate for learning materials and course implementations

## Scaffolding

Requires:

- `just` — task runner. Install via `brew install just`
- `odin` — reference implementation language (this repo is not the reference impl yet)
- SDL3 — only needed for the graphics course impl: `brew install sdl3`

Key tasks (see `justfile`):

```
just learn3d   # run the Pikuma 3D graphics course implementation (Odin + SDL3)
just           # list all tasks
```

## References

- Pikuma, "Learn Computer Graphics Programming": <https://courses.pikuma.com/courses/take/learn-computer-graphics-programming>