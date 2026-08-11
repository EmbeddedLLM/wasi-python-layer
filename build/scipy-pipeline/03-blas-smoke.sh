#!/bin/bash
# Stage 4 / M4: build the _blas_smoke CPython extension (BLAS/LAPACK probe),
# P11-clean, static libopenblas.a + libf2c.a. See smoke/_blas_smoke.c.
#
# Link shape: the repo's proven wasm extension model (same as the layer's
# hand-built extensions) — wasm32-wasip2, -fPIC, -shared, --experimental-pic,
# --unresolved-symbols=import-dynamic, libpython3.14.so; archives in a
# --start-group/--end-group to break f2c<->blas symbol cycles.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
export WASI_SDK_PATH="${WASI_SDK_PATH:-$WASI_BUILD/wasi-sdk}"
CROSS_PREFIX="${CROSS_PREFIX:-$WASI_BUILD/cpython-wasi/install}"
DEPS="$WASI_BUILD/scipy-build/deps"
OUT="$WASI_BUILD/scipy-build/build"
EXT="_blas_smoke.cpython-314-wasm32-wasi.so"
SYSROOT="$WASI_SDK_PATH/share/wasi-sysroot"

mkdir -p "$OUT"
cd "$OUT"

if [ -f "$EXT" ]; then
  echo "[blas-smoke] already built: $OUT/$EXT"
  exit 0
fi

"$WASI_SDK_PATH/bin/clang" \
  --target=wasm32-wasip2 --sysroot="$SYSROOT" -fPIC \
  -Wcast-function-type-strict -Werror=cast-function-type-strict \
  -I"$CROSS_PREFIX/include/python3.14" -I"$DEPS/include" \
  -shared -Wl,--experimental-pic -Wl,--unresolved-symbols=import-dynamic \
  "$HERE/smoke/_blas_smoke.c" \
  "$DEPS/lib/libopenblas.a" "$DEPS/lib/libf2c.a" \
  -lwasi-emulated-mman \
  "$CROSS_PREFIX/lib/libpython3.14.so" \
  -o "$EXT"

echo "[blas-smoke] DONE: $OUT/$EXT"
