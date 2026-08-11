#!/bin/bash
# Stage 2 / M2: build libf2c.a (CLAPACK 3.2.1, f2c Fortran runtime ABI) for
# wasm32-wasip2 with wasi-sdk-27.
#
# Why: scipy 1.18 is Fortran-free as a Meson project language, but BLAS/LAPACK
# still expose the legacy f2c runtime ABI (pow_dd, pow_di, s_copy, ...) that
# converted numerical code links against. Pyodide solves this with CLAPACK's
# libf2c — same approach here, adapted from their recipe (patches/).
#
# Lessons applied (see design_docs):
#  - arith.h is codegen: compile+run arithchk.c. WASI has no ./a.out — the
#    helper is built as wasm32-wasip1 (Node's WASI is preview1) and executed
#    via run-wasi-preview1.js; the helper is codegen-only, never shipped.
#    (P9-adjacent: host-vs-target codegen split, cf. cross-python.sh.)
#  - libf2c.a MUST contain wasm objects only (Stage 2 gate) — a host-ELF
#    object would poison the scipy link later (cf. "Never ship host objects").
#  - The f2c return-type consistency patch (0004) is kept: wasm C enforces
#    void-vs-int return types at the ABI level, unlike x86-64 C.
#  - 0003 (LAPACK SRC aux symbols) is deliberately NOT applied: we never build
#    LAPACK SRC, and OpenBLAS supplies those symbols in Stage 3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
export WASI_SDK_PATH="${WASI_SDK_PATH:-$WASI_BUILD/wasi-sdk}"
BUILD="$WASI_BUILD/scipy-build"
DEPS="$BUILD/deps"
SRC="$BUILD/CLAPACK-3.2.1"
CLAPACK_SHA256="6dc4c382164beec8aaed8fd2acc36ad24232c406eda6db462bd4c41d5e455fac"
CLAPACK_URL="https://www.netlib.org/clapack/clapack.tgz"
CLAPACK_URL_ALT="https://web.archive.org/web/20260509221335/https://www.netlib.org/clapack/clapack.tgz"

mkdir -p "$BUILD" "$DEPS/lib" "$DEPS/include"

if [ -f "$DEPS/lib/libf2c.a" ] && [ -f "$DEPS/include/f2c.h" ]; then
  echo "[libf2c] already built: $DEPS/lib/libf2c.a"
  exit 0
fi

# ── download (sha256-pinned) ───────────────────────────────────────────────
if [ ! -f "$BUILD/clapack.tgz" ]; then
  echo "[libf2c] downloading CLAPACK 3.2.1 ..."
  curl -fsSL --max-time 120 "$CLAPACK_URL" -o "$BUILD/clapack.tgz" \
    || curl -fsSL --max-time 120 "$CLAPACK_URL_ALT" -o "$BUILD/clapack.tgz"
fi
echo "$CLAPACK_SHA256  $BUILD/clapack.tgz" | sha256sum -c -

# ── extract (idempotent) ───────────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
  tar xzf "$BUILD/clapack.tgz" -C "$BUILD"
fi

cd "$SRC"

# ── patches (idempotent: already-applied hunks are skipped) ────────────────
for p in "$HERE"/patches/libf2c/*.patch; do
  echo "[libf2c] applying $(basename "$p")"
  if patch -p1 --forward --dry-run -s < "$p" 2>/dev/null; then
    patch -p1 --forward -s < "$p"
  else
    echo "  (already applied or not applicable — $(basename "$p"))"
  fi
done
cp -f "$HERE/make.inc.wasi" make.inc
sed -i "s|^ARITH_RUNNER = .*|ARITH_RUNNER = $HERE/run-wasi-preview1.js|" make.inc

# ── build ──────────────────────────────────────────────────────────────────
echo "[libf2c] building f2clib (wasm32-wasip2)..."
make f2clib

cp -f INCLUDE/f2c.h "$DEPS/include/f2c.h"
# `clapack_install` moves the archive up one level (F2CLIBS/libf2c.a).
cp -f F2CLIBS/libf2c.a "$DEPS/lib/libf2c.a"

# ── Stage 2 validation ─────────────────────────────────────────────────────
echo "[libf2c] validating..."
OBJ="$("$WASI_SDK_PATH/bin/llvm-ar" t "$DEPS/lib/libf2c.a" | head -1)"
mkdir -p /tmp/f2c-check && ( cd /tmp/f2c-check && "$WASI_SDK_PATH/bin/llvm-ar" x "$DEPS/lib/libf2c.a" && file ./*.o 2>/dev/null | head -2 || true )
for sym in pow_dd pow_di s_copy s_cmp i_len; do
  if "$WASI_SDK_PATH/bin/llvm-nm" "$DEPS/lib/libf2c.a" 2>/dev/null | grep -q " $sym$"; then
    echo "  [ok] symbol $sym"
  else
    echo "  [FAIL] missing symbol $sym" >&2
    exit 1
  fi
done
echo "[libf2c] DONE: $DEPS/lib/libf2c.a ($(du -h "$DEPS/lib/libf2c.a" | cut -f1)) + f2c.h"
