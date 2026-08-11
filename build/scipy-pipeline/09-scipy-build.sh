#!/bin/bash
# Stage 11 / M10: first SciPy compile (meson). Classify failures per the
# design doc (A: missing WASI APIs, B: BLAS/LAPACK ABI, C: missing f2c
# symbols, D: C++ runtime) instead of patching randomly. All config from
# 08-scipy-cross.sh must be applied first (it exports the env).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
export WASI_SDK_PATH="${WASI_SDK_PATH:-$WASI_BUILD/wasi-sdk}"
SRC="$WASI_BUILD/scipy-1.18.0"
LOG="$WASI_BUILD/scipy-build/meson-compile.log"

test -d "$SRC/build" || { echo "[scipy-build] run 08-scipy-cross.sh first" >&2; exit 1; }

# same env as the configure step
DEPS="$WASI_BUILD/scipy-build/deps"
NUPY="$WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages"
export PATH="$HERE:$WASI_BUILD/build-venv/bin:$PATH"
export CC="$WASI_SDK_PATH/bin/clang"
export CXX="$WASI_SDK_PATH/bin/clang++"
export PYTHONPATH="$HERE/numpy-stub${PYTHONPATH:+:$PYTHONPATH}:$NUPY"
export LDFLAGS="--target=wasm32-wasip2 -shared"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$NUPY/numpy/_core/lib/pkgconfig"

cd "$SRC"
echo "[scipy-build] meson compile (log: $LOG)"
meson compile -C build -v > "$LOG" 2>&1 || {
  echo "[scipy-build] COMPILE FAILED — first error classes:" >&2
  grep -m6 -E "error:|Error [0-9]+|FAILED|undefined symbol" "$LOG" | head -12 >&2 || true
  exit 1
}
echo "[scipy-build] COMPILE OK"

# ── install (fresh destdir — meson install does not clean stale files) ────
INSTALL="$WASI_BUILD/scipy-build/install"
rm -rf "$INSTALL"
PATH="$WASI_BUILD/build-venv/bin:$PATH" meson install -C build --destdir "$INSTALL" \
  > "$WASI_BUILD/scipy-build/meson-install.log" 2>&1
echo "[scipy-build] INSTALL OK: $INSTALL/usr/local/lib/python3.14/site-packages/scipy"
