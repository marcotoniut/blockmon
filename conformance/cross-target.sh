#!/usr/bin/env bash
# Cross-target conformance for the current corpora: emit the v1 tree and
# Transition 1 expansion tiers on each target, then compare each
# byte-for-byte against the native run and the committed vectors.
# The archived v0 corpora are digest-verified evidence
# (just g0a-archive), never regenerated: their generator's world_root is now
# the v1 commitment, so a fresh run of it proves nothing about the archive.
# Containers pin the dev-2026-07 release. The native leg builds with whichever
# odin is on PATH; in the pinned devshell that is dev-2026-08. A green run
# therefore also confirms agreement between those two compilers. Not a
# framework.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
OUT="${1:-/tmp/g0a-cross}"
mkdir -p "$OUT"

ODIN_REL=https://github.com/odin-lang/Odin/releases/download/dev-2026-07

# ---- native (whichever host runs this) --------------------------------------
# Named from the host rather than assumed: a scheduled Linux runner must not
# emit a file called darwin_arm64.json.
NATIVE="native_$(uname -s | tr '[:upper:]' '[:lower:]')_$(uname -m)"
# kind:generator package, for each corpus that travels
GENS="tree:gen-tree t1:gen-t1-v1"
mkdir -p "$REPO/build"
for k in $GENS; do
  odin build "$REPO/conformance/${k#*:}" -out:"$REPO/build/xt-${k#*:}" -o:none
  "$REPO/build/xt-${k#*:}" > "$OUT/$NATIVE.${k%%:*}.json"
done

linux_run() { # 1=docker platform, 2=odin release arch, 3=output name
  # Both corpora travel back as a tar stream on stdout; a host-path volume
  # would depend on the docker VM sharing $OUT, which colima does not.
  docker run --rm --platform "$1" -e GENS="$GENS" -v "$REPO":/w:ro debian:bookworm bash -c "
    set -euo pipefail
    for i in 1 2 3 4 5; do apt-get update -qq >&2 && break || sleep 5; done
    { apt-get install -y -qq curl ca-certificates clang >/dev/null; } >&2
    curl -fsSL --retry 5 --retry-all-errors $ODIN_REL/odin-linux-$2-dev-2026-07.tar.gz -o /tmp/odin.tgz >&2
    tar xzf /tmp/odin.tgz -C /opt >&2
    ODIN=\$(find /opt -maxdepth 2 -name odin -type f | head -1)
    mkdir /tmp/out
    for k in \$GENS; do
      \"\$ODIN\" build /w/conformance/\${k#*:} -out:/tmp/\${k%%:*} -o:none >&2
      /tmp/\${k%%:*} > /tmp/out/$3.\${k%%:*}.json
    done
    tar cf - -C /tmp/out .
  " | tar xf - -C "$OUT"
}

# ---- linux_arm64 (native arch container) --------------------------------------
linux_run linux/arm64 arm64 linux_arm64

# ---- linux_amd64 (x86-64 via emulation) ----------------------------------------
linux_run linux/amd64 amd64 linux_amd64

# ---- linux_riscv64: cross-build in the arm64 container, run under qemu-user ----
docker run --rm --platform linux/arm64 -e GENS="$GENS" -v "$REPO":/w:ro debian:bookworm bash -c "
  set -euo pipefail
  for i in 1 2 3 4 5; do apt-get update -qq >&2 && break || sleep 5; done
  { apt-get install -y -qq curl ca-certificates clang \
      qemu-user-static gcc-riscv64-linux-gnu >/dev/null; } >&2
  curl -fsSL --retry 5 --retry-all-errors $ODIN_REL/odin-linux-arm64-dev-2026-07.tar.gz -o /tmp/odin.tgz >&2
  tar xzf /tmp/odin.tgz -C /opt >&2
  ODIN=\$(find /opt -maxdepth 2 -name odin -type f | head -1)
  mkdir /tmp/out
  for k in \$GENS; do
    \"\$ODIN\" build /w/conformance/\${k#*:} -out:/tmp/\${k%%:*}-rv64 -o:none -target:linux_riscv64 \
      -extra-linker-flags:'--target=riscv64-linux-gnu --gcc-toolchain=/usr -fuse-ld=bfd' >&2
    qemu-riscv64-static -L /usr/riscv64-linux-gnu /tmp/\${k%%:*}-rv64 > /tmp/out/linux_riscv64.\${k%%:*}.json
  done
  tar cf - -C /tmp/out .
" | tar xf - -C "$OUT" || { echo "riscv64 leg failed" >&2; rm -f "$OUT"/linux_riscv64.*.json; }

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
for kind in tree t1; do
  committed="$REPO/conformance/vectors/g0a-$kind-v1-expansion.json"
  native="$OUT/$NATIVE.$kind.json"
  if cmp -s "$committed" "$native"; then
    echo "IDENTICAL  $NATIVE.$kind.json == committed $(basename "$committed")"
  else
    echo "MISMATCH   $NATIVE.$kind.json vs committed vectors"
    status=1
  fi
  for t in linux_arm64 linux_amd64 linux_riscv64; do
    f="$OUT/$t.$kind.json"
    if [ ! -s "$f" ]; then
      echo "MISSING    $t.$kind.json (leg produced no output)"
      status=1
    elif cmp -s "$native" "$f"; then
      echo "IDENTICAL  $t.$kind.json == $NATIVE.$kind.json"
    else
      echo "MISMATCH   $t.$kind.json"
      status=1
    fi
  done
done
[ "$status" -eq 0 ] || echo "INCOMPLETE: not tri-target evidence" >&2
exit $status
