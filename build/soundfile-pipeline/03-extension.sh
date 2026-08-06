#!/bin/bash
# Stage 3: build the _soundfile_native CPython extension for wasm32-wasip2.
# Pure C, no cffi/ctypes/dlopen; late-link shape (dylink) for the eryx factory.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
SF_BUILD="$WASI_BUILD/libsndfile-build"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
OUT="$SF_BUILD/ext"

mkdir -p "$OUT"

echo ">>> Building _soundfile_native..."
"$WASI_SDK/bin/clang" \
    --target=wasm32-wasip2 \
    --sysroot="$WASI_SDK/share/wasi-sysroot" \
    -O2 -fPIC -fvisibility=hidden \
    -I"$CROSS_PREFIX/include/python3.14" \
    -I"$SF_BUILD/libsndfile-1.2.2/include" \
    "$HERE/_soundfile_native.c" \
    -shared -fuse-ld=lld \
    -Wl,--unresolved-symbols=import-dynamic \
    "$CROSS_PREFIX/lib/libpython3.14.so" \
    "$SF_BUILD/install/lib/libsndfile.a" \
    -o "$OUT/_soundfile_native.cpython-314-wasm32-wasi.so"

ls -la "$OUT/_soundfile_native.cpython-314-wasm32-wasi.so"
