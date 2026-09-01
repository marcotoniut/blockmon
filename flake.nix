{
  # Pinned dev toolchain, devShell only.
  # Nix owns tool versions; just owns workflows; the G0 gates own semantics.
  # A green shell proves the environment, never kernel determinism.
  description = "Blockmon development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            odin # kernel, conformance, probe; dev-2026-07a at the locked revision
            foundry # forge/anvil/cast; gate-revalidated against the locked version
            python3 # conformance/check.py (stdlib only)
            ruff # check.py lint and format gate
            shellcheck # cross-target.sh and the slice-b harness scripts
            lefthook # git hooks; `just hooks` installs them
            just
            docker-client # used only by conformance/cross-target.sh; daemon stays external
          ];
          # Deliberately absent:
          #  - solc: foundry.toml is the single source of truth for the Solidity
          #    compiler (0.8.24, fetched once into forge's svm cache). A shell
          #    solc at a different version would add a second truth and enforce
          #    nothing. Offline enforcement is Slice 2.
          #  - sdl3: needed only to link learning/, which the gates type-check
          #    but never run.
          #  - rust: conformance/g0c/impl pins its own toolchain via
          #    rust-toolchain.toml; a shell rustc would be a second truth.
          #    The G0c lint gate runs from its own CI job.
        };
      });
    };
}
