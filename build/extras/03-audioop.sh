#!/bin/bash
# extras/03-audioop.sh — audioop-lts (single C file backport of stdlib audioop).
#
# Same recipe as regex: audioop/_audioop.c is self-contained CPython C API;
# late-link shape. Module name: audioop (the removed 3.13 stdlib module).
#
# Usage: SITE=/path/site-packages bash 03-audioop.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
AO_VERSION="0.2.2"
BUILD="$WASI_BUILD/audioop-build"

mkdir -p "$BUILD"

echo ">>> [extras/03] Fetching audioop-lts $AO_VERSION sdist..."
AO_URL="$(curl -s "https://pypi.org/pypi/audioop-lts/$AO_VERSION/json" \
    | jq -r '.urls[] | select(.filename | endswith(".tar.gz")) | .url' | head -1)"
[ -n "$AO_URL" ] || { echo "ERROR: audioop-lts sdist not found"; exit 1; }
if [ ! -d "$BUILD/audioop_lts-$AO_VERSION" ]; then
    curl -sL -o "$BUILD/audioop_lts-$AO_VERSION.tar.gz" "$AO_URL"
    tar -xf "$BUILD/audioop_lts-$AO_VERSION.tar.gz" -C "$BUILD"
fi

echo ">>> [extras/03] Copying audioop package + compiling _audioop..."
rm -rf "$SITE/audioop"
mkdir -p "$SITE/audioop"
cp "$BUILD/audioop_lts-$AO_VERSION/audioop/"*.py "$SITE/audioop/"
cp "$BUILD/audioop_lts-$AO_VERSION/audioop/"*.pyi "$SITE/audioop/" 2>/dev/null || true
cp "$BUILD/audioop_lts-$AO_VERSION/audioop/py.typed" "$SITE/audioop/" 2>/dev/null || true
"$WASI_SDK/bin/clang" \
    --target=wasm32-wasip2 \
    --sysroot="$WASI_SDK/share/wasi-sysroot" \
    -O2 -fPIC -fvisibility=hidden \
    -I"$CROSS_PREFIX/include/python3.14" \
    "$BUILD/audioop_lts-$AO_VERSION/audioop/_audioop.c" \
    -shared -fuse-ld=lld \
    -Wl,--unresolved-symbols=import-dynamic \
    "$CROSS_PREFIX/lib/libpython3.14.so" \
    -o "$SITE/audioop/_audioop.cpython-314-wasm32-wasi.so"

ls -la "$SITE/audioop/"
