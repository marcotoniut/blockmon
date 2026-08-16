# Blockmon task runner.
# Requires: just, odin (dev-2026-07+), SDL3 (brew install sdl3)
# See README.md for refs (Pikuma 3D graphics course) and scaffolding.

default:
	@just --list

# Run the Pikuma 3D graphics course implementation (Odin + SDL3)
learn3d:
	mkdir -p build
	odin run ./learning/3d-computer-graphics-programming -out:./build/learn3d

