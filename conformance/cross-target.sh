#!/usr/bin/env bash
# Cross-target conformance for the current corpus: emit the v1 tree expansion
# tier on each target and compare byte-for-byte against the native run and the
# committed vectors. The archived v0 corpora are digest-verified evidence
# (just g0a-archive), never regenerated: their generator's world_root is now
# the v1 commitment, so a fresh run of it proves nothing about the archive.
# Hard-coded to the current toolchain pin (odin dev-2026-07); not a framework.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
OUT="${1:-/tmp/g0a-cross}"
mkdir -p "$OUT"

ODIN_REL=https://github.com/odin-lang/Odin/releases/download/dev-2026-07

# ---- native (darwin_arm64) ---------------------------------------------------
mkdir -p "$REPO/build"
odin build "$REPO/conformance/gen-tree" -out:"$REPO/build/xt-gen-tree" -o:none
"$REPO/build/xt-gen-tree" > "$OUT/darwin_arm64.json"

linux_run() { # 1=docker platform, 2=odin release arch, 3=output name
  # Both corpora travel back as a tar stream on stdout; a host-path volume
  # would depend on the docker VM sharing $OUT, which colima does not.
  docker run --rm --platform "$1" -v "$REPO":/w:ro debian:bookworm bash -c "
    set -euo pipefail
    for i in 1 2 3 4 5; do apt-get update -qq >&2 && break || sleep 5; done
    { apt-get install -y -qq curl ca-certificates clang >/dev/null; } >&2
    curl -fsSL --retry 5 --retry-all-errors $ODIN_REL/odin-linux-$2-dev-2026-07.tar.gz -o /tmp/odin.tgz >&2
    tar xzf /tmp/odin.tgz -C /opt >&2
    ODIN=\$(find /opt -maxdepth 2 -name odin -type f | head -1)
    \"\$ODIN\" build /w/conformance/gen-tree -out:/tmp/gen -o:none >&2
    mkdir /tmp/out
    /tmp/gen > /tmp/out/$3.json
    tar cf - -C /tmp/out .
  " | tar xf - -C "$OUT"
}

# ---- linux_arm64 (native arch container) --------------------------------------
linux_run linux/arm64 arm64 linux_arm64

# ---- linux_amd64 (x86-64 via emulation) ----------------------------------------
linux_run linux/amd64 amd64 linux_amd64

# ---- linux_riscv64: cross-build in the arm64 container, run under qemu-user ----
docker run --rm --platform linux/arm64 -v "$REPO":/w:ro debian:bookworm bash -c "
  set -euo pipefail
  for i in 1 2 3 4 5; do apt-get update -qq >&2 && break || sleep 5; done
  { apt-get install -y -qq curl ca-certificates clang \
      qemu-user-static gcc-riscv64-linux-gnu >/dev/null; } >&2
  curl -fsSL --retry 5 --retry-all-errors $ODIN_REL/odin-linux-arm64-dev-2026-07.tar.gz -o /tmp/odin.tgz >&2
  tar xzf /tmp/odin.tgz -C /opt >&2
  ODIN=\$(find /opt -maxdepth 2 -name odin -type f | head -1)
  \"\$ODIN\" build /w/conformance/gen-tree -out:/tmp/gen-rv64 -o:none -target:linux_riscv64 \
    -extra-linker-flags:'--target=riscv64-linux-gnu --gcc-toolchain=/usr -fuse-ld=bfd' >&2
  mkdir /tmp/out
  qemu-riscv64-static -L /usr/riscv64-linux-gnu /tmp/gen-rv64 > /tmp/out/linux_riscv64.json
  tar cf - -C /tmp/out .
" | tar xf - -C "$OUT" || { echo "riscv64 leg failed" >&2; rm -f "$OUT/linux_riscv64.json"; }

# ---- compare -------------------------------------------------------------------
# Every target must be present and byte-identical, and identical to the
# committed corpus: agreement between targets alone would also bless a
# generator that drifted everywhere at once. A leg that produced no output is
# a failed run, not a smaller green one.
echo
status=0
for f in "$OUT"/*.json; do
  shasum -a 256 "$f"
done
COMMITTED="$REPO/conformance/vectors/g0a-tree-v1-expansion.json"
if cmp -s "$COMMITTED" "$OUT/darwin_arm64.json"; then
  echo "IDENTICAL  darwin_arm64.json == committed g0a-tree-v1-expansion.json"
else
  echo "MISMATCH   darwin_arm64.json vs committed vectors"
  status=1
fi
for t in linux_arm64 linux_amd64 linux_riscv64; do
  f="$OUT/$t.json"
  if [ ! -s "$f" ]; then
    echo "MISSING    $t.json (leg produced no output)"
    status=1
  elif cmp -s "$OUT/darwin_arm64.json" "$f"; then
    echo "IDENTICAL  $t.json == darwin_arm64.json"
  else
    echo "MISMATCH   $t.json"
    status=1
  fi
done
[ "$status" -eq 0 ] || echo "INCOMPLETE: not tri-target evidence" >&2
exit $status
