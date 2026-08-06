#!/bin/bash
# extras/05-orjson.sh — orjson (Rust/pyo3 cdylib), the new Rust→wasm32-wasip1 pipeline.
#
# The build is a cross-compile of a pyo3-ffi cdylib. Three non-obvious pieces
# (all captured here, lessons in the worklog):
#   1. pyo3 cross: PYO3_CROSS_PYTHON (native 3.14) + PYO3_CROSS_LIB_DIR (wasm libpython3.14.a).
#   2. cc-rs (bundled yyjson C): CC_wasm32_wasip1 = wasi-sdk clang + WASI_SDK_PATH/SYSROOT.
#   3. The cdylib must be a WASI SHARED LIBRARY (dylink.0) for the late-link model:
#      RUSTFLAGS="-C relocation-model=pic -C link-arg=--experimental-pic -C link-arg=--shared",
#      and rustup's non-PIC self-contained libc must be replaced by wasi-sdk's PIC
#      libc (-C link-self-contained=no -C link-arg=-L<sysroot>/lib/wasm32-wasip1).
#
# Usage: SITE=/path/site-packages bash 05-orjson.sh   (default $WASI_BUILD/extras-site)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
OJ_VERSION="3.11.9"
BUILD="$WASI_BUILD/orjson-build"

mkdir -p "$BUILD"

echo ">>> [extras/05] Fetching orjson $OJ_VERSION sdist..."
OJ_URL="$(curl -s "https://pypi.org/pypi/orjson/$OJ_VERSION/json" \
    | jq -r '.urls[] | select(.filename | endswith(".tar.gz")) | .url' | head -1)"
[ -n "$OJ_URL" ] || { echo "ERROR: orjson sdist not found"; exit 1; }
if [ ! -d "$BUILD/orjson-$OJ_VERSION" ]; then
    curl -sL -o "$BUILD/orjson-$OJ_VERSION.tar.gz" "$OJ_URL"
    tar -xf "$BUILD/orjson-$OJ_VERSION.tar.gz" -C "$BUILD"
fi
cd "$BUILD/orjson-$OJ_VERSION"

echo ">>> [extras/05] Cross-compiling orjson for wasm32-wasip1 (rust 1.95)..."
# Write a pyo3-build-config config file with suppress_build_script_link_lines=true:
# with the default cross config, pyo3 emits rustc-link-lib=python3.14, which makes
# rust-lld link the whole libpython archive -> the .so imports the ENTIRE python
# symbol table (2972 Py* incl. PyExpat_*), and the factory component link fails
# on symbols the runtime python doesn't export. Suppressed, only the symbols
# orjson actually references stay as imports (94 Py*), all public API.
PYO3_CONFIG_FILE="$BUILD/pyo3-wasm-config.txt"
cat > "$PYO3_CONFIG_FILE" <<EOF
implementation=CPython
version=3.14
shared=false
abi3=false
lib_name=python3.14
lib_dir=$CROSS_PREFIX/lib
pointer_width=32
build_flags=
python_framework_prefix=
suppress_build_script_link_lines=true
EOF
# Ensure the Rust toolchain + wasm32-wasip1 target exist (runners/containers
# lack it by default; the local dev machine had it installed — gate caught the
# gap on the first from-scratch CI run, 2026-08-06). Must come BEFORE the env
# prefix below — a dangling backslash-continuation would drop the env vars.
if ! rustup target list --installed 2>/dev/null | grep -q "^wasm32-wasip1$"; then
    echo ">>> [extras/05] installing wasm32-wasip1 target..."
    rustup target add wasm32-wasip1
fi
PYO3_CONFIG_FILE="$PYO3_CONFIG_FILE" \
CC_wasm32_wasip1="$WASI_SDK/bin/clang" \
WASI_SDK_PATH="$WASI_SDK" \
WASI_SYSROOT="$WASI_SDK/share/wasi-sysroot" \
RUSTFLAGS="-C relocation-model=pic -C link-arg=--experimental-pic \
-C link-arg=--shared -C link-self-contained=no \
-C link-arg=-L$WASI_SDK/share/wasi-sysroot/lib/wasm32-wasip1" \
cargo +1.95 build --release --target wasm32-wasip1

echo ">>> [extras/05] Assembling orjson package..."
rm -rf "$SITE/orjson"
mkdir -p "$SITE/orjson"
cp "$BUILD/orjson-$OJ_VERSION/pysrc/orjson/"*.py "$SITE/orjson/"
cp target/wasm32-wasip1/release/orjson.wasm "$SITE/orjson/orjson.cpython-314-wasm32-wasi.so"
# Guard: the module must be a WASI dylib (dylink.0), not a static reactor.
"$WASI_SDK/bin/llvm-objdump" -h "$SITE/orjson/orjson.cpython-314-wasm32-wasi.so" | grep -q dylink \
    || { echo "ERROR: orjson .so has no dylink section"; exit 1; }

ls -la "$SITE/orjson/"
