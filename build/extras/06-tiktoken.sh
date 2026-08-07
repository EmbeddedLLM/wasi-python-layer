#!/bin/bash
# extras/06-tiktoken.sh — tiktoken (Rust/pyo3 cdylib) + baked tokenizer data.
#
# Build: cargo +nightly -Zbuild-std. The rustup std rlibs for wasm32-wasip1 are
# NOT PIC (no bitcode for fat-LTO recompilation), so a PIC shared-lib link fails
# with "R_WASM_MEMORY_ADDR_SLEB ... recompile with -fPIC" against libstd for any
# crate whose std usage pulls non-PIC data objects (orjson's success was luck:
# its std usage avoids those objects). Rebuilding std from source with
# `-C relocation-model=pic` (build-std) fixes it for all crates.
# NOTE: with -Zbuild-std, rustc drops --allow-undefined from the link line, so
# it must be passed explicitly (-C link-arg=--allow-undefined) or the Py* imports
# become hard link errors. Worklog Checkpoint 5 lessons.
#
# Data: the sandbox has no network, so the standard vocab files are baked into
# tiktoken/data/ and the blob URLs in tiktoken_ext/openai_public.py are patched
# to /site-packages/tiktoken/data/<name> (site-packages is mounted read-only at
# runtime). load.py's read_file() opens plain paths directly, so `requests` is
# never imported. gpt2() (the gpt-2 vocab.bpe/encoder.json pair) is NOT baked —
# use r50k_base, which is the modern alias for gpt-2 models.
#
# Usage: SITE=/path/site-packages bash 06-tiktoken.sh   (default $WASI_BUILD/extras-site)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
TT_VERSION="0.13.0"
BUILD="$WASI_BUILD/tiktoken-build"

mkdir -p "$BUILD" "$SITE"

echo ">>> [extras/06] Fetching tiktoken $TT_VERSION sdist..."
TT_URL="$(curl -s "https://pypi.org/pypi/tiktoken/$TT_VERSION/json" \
    | jq -r '.urls[] | select(.filename | endswith(".tar.gz")) | .url' | head -1)"
[ -n "$TT_URL" ] || { echo "ERROR: tiktoken sdist not found"; exit 1; }
if [ ! -d "$BUILD/tiktoken-$TT_VERSION" ]; then
    curl -sL -o "$BUILD/tiktoken-$TT_VERSION.tar.gz" "$TT_URL"
    tar -xf "$BUILD/tiktoken-$TT_VERSION.tar.gz" -C "$BUILD"
fi
cd "$BUILD/tiktoken-$TT_VERSION"

echo ">>> [extras/06] Ensuring nightly + wasm32-wasip1 target + rust-src..."
rustup +nightly target add wasm32-wasip1 >/dev/null 2>&1 || true
rustup +nightly component add rust-src >/dev/null 2>&1 || true

echo ">>> [extras/06] Cross-compiling _tiktoken (pyo3 cdylib, build-std PIC std)..."
# Match the verified artifact: fat-LTO + codegen-units=1 release profile.
grep -q 'lto = "fat"' Cargo.toml || printf '\n[profile.release]\nlto = "fat"\ncodegen-units = 1\n' >> Cargo.toml
cat > pyo3-wasm-config.txt <<EOF
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
PYO3_CONFIG_FILE="$PWD/pyo3-wasm-config.txt" \
CC_wasm32_wasip1="$WASI_SDK/bin/clang" \
WASI_SDK_PATH="$WASI_SDK" \
WASI_SYSROOT="$WASI_SDK/share/wasi-sysroot" \
RUSTFLAGS="-C relocation-model=pic -C link-arg=--experimental-pic \
-C link-arg=--shared -C link-arg=--allow-undefined -C link-self-contained=no \
-C link-arg=-L$WASI_SDK/share/wasi-sysroot/lib/wasm32-wasip1" \
cargo +nightly build -Zbuild-std=std,panic_abort --release \
    --target wasm32-wasip1 --features python

echo ">>> [extras/06] Assembling tiktoken package..."
rm -rf "$SITE/tiktoken" "$SITE/tiktoken_ext"
mkdir -p "$SITE/tiktoken" "$SITE/tiktoken_ext" "$SITE/tiktoken/data"
cp tiktoken/*.py tiktoken/py.typed "$SITE/tiktoken/"
cp tiktoken_ext/*.py "$SITE/tiktoken_ext/"
# pymodule is _tiktoken (src/py.rs) — the crate cdylib is tiktoken.wasm.
cp target/wasm32-wasip1/release/tiktoken.wasm \
    "$SITE/tiktoken/_tiktoken.cpython-314-wasm32-wasi.so"
"$WASI_SDK/bin/llvm-objdump" -h "$SITE/tiktoken/_tiktoken.cpython-314-wasm32-wasi.so" \
    | grep -q dylink || { echo "ERROR: _tiktoken .so has no dylink section"; exit 1; }

echo ">>> [extras/06] Baking tokenizer data (sha256-verified)..."
# expected hashes are the hardcoded values in tiktoken_ext/openai_public.py
declare -A DATA=(
    [r50k_base]="306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930"
    [p50k_base]="94b5ca7dff4d00767bc256fdd1b27e5b17361d7b8a5f968547f9f23eb70d2069"
    [cl100k_base]="223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7"
    [o200k_base]="446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d"
)
for name in "${!DATA[@]}"; do
    curl -fsSL -o "$SITE/tiktoken/data/$name.tiktoken" \
        "https://openaipublic.blob.core.windows.net/encodings/$name.tiktoken"
    actual="$(sha256sum "$SITE/tiktoken/data/$name.tiktoken" | cut -d' ' -f1)"
    [ "$actual" = "${DATA[$name]}" ] || { echo "ERROR: $name.tiktoken sha256 mismatch"; exit 1; }
    echo "  $name.tiktoken ok ($(stat -c%s "$SITE/tiktoken/data/$name.tiktoken") bytes)"
done

echo ">>> [extras/06] Patching openai_public.py blob URLs -> baked data..."
python3 - <<EOF
from pathlib import Path
p = Path("$SITE/tiktoken_ext/openai_public.py")
src = p.read_text()
for name in ("r50k_base", "p50k_base", "cl100k_base", "o200k_base"):
    old = f'"https://openaipublic.blob.core.windows.net/encodings/{name}.tiktoken"'
    new = f'_os.path.join(_TT_DATA, "{name}.tiktoken")'
    assert old in src, f"expected {old} in openai_public.py"
    src = src.replace(old, new)
# Data dir computed relative to this module at runtime, so the layer works under
# ANY site-packages mount prefix (/site-packages for the factory/sandbox path,
# /site-packages-0 for the PythonExecutor session path — v8-kopi plan §13.3).
helper = (
    'import os as _os\n'
    '_TT_DATA = _os.path.join(\n'
    '    _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))), "tiktoken", "data")\n'
)
assert not src.startswith("import os as _os"), "already patched?"
src = helper + src
p.write_text(src)
print("  patched", src.count("_TT_DATA"), "URLs -> self-locating data dir")
EOF

echo ">>> [extras/06] registry.py plugin-scan fallback (wasm pkgutil blind spot)..."
python3 - <<EOF
from pathlib import Path
p = Path("$SITE/tiktoken/registry.py")
src = p.read_text()
old = """    for _, mod_name, _ in plugin_mods:
        mods.append(mod_name)
    return mods"""
new = """    for _, mod_name, _ in plugin_mods:
        mods.append(mod_name)
    if not mods:
        # wasm build (2026-08-05): pkgutil.iter_modules cannot scan the baked
        # namespace package in the guest; fall back to the known plugin module.
        mods.append(tiktoken_ext.__name__ + ".openai_public")
    return mods"""
assert old in src, "registry.py _available_plugin_modules changed upstream"
p.write_text(src.replace(old, new))
print("  patched registry.py")
EOF

ls -la "$SITE/tiktoken/" | head -8
echo ">>> [extras/06] done"
