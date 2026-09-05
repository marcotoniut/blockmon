# Blockmon task runner.
# Requires: just, odin (dev-2026-07+), SDL3 (brew install sdl3)
# See README.md for refs (Pikuma 3D graphics course) and scaffolding.

# Odin static gate: every odin invocation below carries it, so nothing that
# `just lint` rejects can pass any build, test, or gate.
ODIN_VET := "-vet -vet-cast -vet-using-param -strict-style -disallow-do -warnings-as-errors"

default:
	@just --list

# Static gates for every language in the tree.
# Rust is excluded: its crates pin their own toolchains,
# so `just g0c` and `just tree-v1-rust` own fmt and clippy.
lint: lint-odin lint-python lint-shell lint-sol

# Type-checks packages with no main procedure, unreachable by the build
lint-odin:
	#!/usr/bin/env bash
	set -euo pipefail
	# Repo-root .odin files are scratch, not a package
	for pkg in $(git ls-files '*.odin' | xargs -n1 dirname | sort -u | grep -v '^\.$'); do
		odin check ./"$pkg" {{ODIN_VET}} -no-entry-point
	done

lint-python:
	git ls-files '*.py' | xargs ruff check
	git ls-files '*.py' | xargs ruff format --check

lint-shell:
	git ls-files '*.sh' | xargs shellcheck

lint-sol:
	cd prototype/slice-b/contracts && forge fmt --check

# Install lefthook.yml git hooks into this clone. The rc pins LEFTHOOK_BIN to
# the store path so the hook never resolves lefthook from PATH; the profile
# keeps that path alive against garbage collection.
hooks:
	nix develop --profile .git/nix-devshell -c bash -c 'printf "LEFTHOOK_BIN=%s\n" "$(command -v lefthook)" > .git/lefthook-rc && lefthook install'

# Devshell entry costs 30s of re-evaluation if tracked files changed.
# Pay that cost only when a tool is missing.
[private]
gated +args:
	#!/usr/bin/env bash
	set -euo pipefail
	# Provenance beats presence: a wrong-version tool or a broken shim must not
	# pass a gate, even if command -v finds it
	for t in odin ruff shellcheck forge; do
		case "$(command -v "$t" 2>/dev/null || true)" in
		/nix/store/*) ;;
		*) exec nix develop -c just {{args}} ;;
		esac
	done
	just {{args}}

# Run the Pikuma 3D graphics course implementation (Odin + SDL3)
learn3d:
	mkdir -p build
	odin run ./learning/3d-computer-graphics-programming -out:./build/learn3d -o:none {{ODIN_VET}}

# Slice B: contract tests (Foundry)
slice-b-test:
	cd prototype/slice-b/contracts && forge test

# Slice B: run the Odin protocol probe alone
slice-b-probe:
	mkdir -p build
	odin run ./prototype/slice-b/probe -out:./build/probe -o:none {{ODIN_VET}}

# Slice B: full E2E round trip against a local anvil
slice-b-e2e:
	bash ./prototype/slice-b/e2e.sh

# Slice B: dual-process battle, automated (chain, one battle, two participant processes, settlement)
slice-b-battle-e2e:
	bash ./prototype/slice-b/battle.sh auto

# Slice B: dual-process battle, manual. Opens the battle, prints the two
# participant commands, settles once both have produced channel evidence.
slice-b-battle:
	bash ./prototype/slice-b/battle.sh manual

# Slice B: participant A, against the battle opened by `just slice-b-battle`
slice-b-player-a:
	mkdir -p build
	odin build ./prototype/slice-b/player-a -out:./build/player-a -o:none {{ODIN_VET}}
	./build/player-a play ./build/battle-run/battle.json ./build/battle-run

# Slice B: participant B, against the battle opened by `just slice-b-battle`
slice-b-player-b:
	mkdir -p build
	odin build ./prototype/slice-b/player-b -out:./build/player-b -o:none {{ODIN_VET}}
	./build/player-b play ./build/battle-run/battle.json ./build/battle-run

# Transition 1 kernel invariant suite
kernel-test:
	mkdir -p build
	odin test ./protocol/kernel -out:./build/kernel-test {{ODIN_VET}}

# G0b: deterministic kernel property/fuzz run (seed, singles, sequences override)
# Default seed = the harness SEED_DEFAULT (0xB10C0DE5EED), so `just g0b` and a
# bare ./build/g0b-fuzz replay the same corpus.
g0b seed="12166583181037" singles="1000000" sequences="20000":
	mkdir -p build
	odin build ./conformance/fuzz -out:./build/g0b-fuzz -o:speed {{ODIN_VET}}
	./build/g0b-fuzz {{seed}} {{singles}} {{sequences}}

# G0a: regenerate golden vectors (seed + expansion) and verify with the independent checker
g0a:
	mkdir -p build conformance/vectors
	odin build ./conformance/gen -out:./build/g0a-gen -o:none {{ODIN_VET}}
	./build/g0a-gen > conformance/vectors/g0a-vectors.json
	./build/g0a-gen expansion > conformance/vectors/g0a-expansion.json
	python3 conformance/check.py

# v1 tree: the independently derived Rust checker against both v1 tiers
tree-v1-rust:
	cd conformance/tree-v1/impl && cargo fmt --check && cargo clippy --quiet --all-targets --all-features && cargo test --release --quiet && cargo run --release --quiet -- ../../vectors/g0a-tree-v1.json ../../vectors/g0a-tree-v1-expansion.json

# v1 tree: the Odin reference must reproduce the hand-derived constitutional vectors
tree-v1:
	mkdir -p build
	odin build ./conformance/tree -out:./build/tree-v1 -o:none {{ODIN_VET}}
	./build/tree-v1
	odin build ./conformance/gen-tree -out:./build/gen-tree -o:none {{ODIN_VET}}
	./build/gen-tree > conformance/vectors/g0a-tree-v1-expansion.json

# G0c: cleanroom Rust checker (fmt + clippy gate, then both corpora)
g0c:
	cd conformance/g0c/impl && cargo fmt --check && cargo clippy --quiet --all-targets --all-features && cargo run --quiet -- ../../vectors/g0a-vectors.json ../../vectors/g0a-expansion.json

