#!/usr/bin/env bash
# G0a cross-target conformance: emit the golden-vector corpus on each target
# and compare artefacts byte-for-byte against the native run.
# Hard-coded to the current toolchain pin (odin dev-2026-07); not a framework.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
OUT="${1:-/tmp/g0a-cross}"
mkdir -p "$OUT"

ODIN_REL=https://github.com/odin-lang/Odin/releases/download/dev-2026-07

# ---- native (darwin_arm64) ---------------------------------------------------
mkdir -p "$REPO/build"
odin build "$REPO/conformance/gen" -out:"$REPO/build/g0a-gen" -o:none
"$REPO/build/g0a-gen" > "$OUT/darwin_arm64.json"
"$REPO/build/g0a-gen" expansion > "$OUT/darwin_arm64-expansion.json"

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
    \"\$ODIN\" build /w/conformance/gen -out:/tmp/gen -o:none >&2
    mkdir /tmp/out
    /tmp/gen > /tmp/out/$3.json
    /tmp/gen expansion > /tmp/out/$3-expansion.json
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
  \"\$ODIN\" build /w/conformance/gen -out:/tmp/gen-rv64 -o:none -target:linux_riscv64 \
    -extra-linker-flags:'--target=riscv64-linux-gnu --gcc-toolchain=/usr -fuse-ld=bfd' >&2
  mkdir /tmp/out
  qemu-riscv64-static -L /usr/riscv64-linux-gnu /tmp/gen-rv64 > /tmp/out/linux_riscv64.json
  qemu-riscv64-static -L /usr/riscv64-linux-gnu /tmp/gen-rv64 expansion > /tmp/out/linux_riscv64-expansion.json
  tar cf - -C /tmp/out .
" | tar xf - -C "$OUT" || { echo "riscv64 leg failed" >&2; rm -f "$OUT/linux_riscv64.json" "$OUT/linux_riscv64-expansion.json"; }

# ---- compare -------------------------------------------------------------------
# Every target G0a names must be present and byte-identical, for both corpora;
# a leg that failed to produce output is a failed run, not a smaller green one.
echo
status=0
for f in "$OUT"/*.json; do
  shasum -a 256 "$f"
done
for t in linux_arm64 linux_amd64 linux_riscv64; do
  for suffix in "" "-expansion"; do
    f="$OUT/$t$suffix.json"
    if [ ! -s "$f" ]; then
      echo "MISSING    $t$suffix.json (leg produced no output)"
      status=1
    elif cmp -s "$OUT/darwin_arm64$suffix.json" "$f"; then
      echo "IDENTICAL  $t$suffix.json == darwin_arm64$suffix.json"
    else
      echo "MISMATCH   $t$suffix.json"
      status=1
    fi
  done
done
[ "$status" -eq 0 ] || echo "INCOMPLETE: not tri-target evidence" >&2
exit $status
