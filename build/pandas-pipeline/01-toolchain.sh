#!/bin/bash
# Stage 1: toolchain + CPython prerequisites.
#   - wasi-sdk-27 (clang 20.1.8-wasi-sdk -- the same compiler eryx's CPython used)
#   - dicej/cpython fork (branch v3.14.0-wasi-sdk-27 == eryx's exact CPython commit)
#   - native host CPython 3.14 (the cross-compile runs codegen on the host)
#   - wasm CPython 3.14 (CROSS_PREFIX: libpython3.14.so + headers + sysconfigdata)
#   - cross-python.sh (host python reporting the wasm sysconfig)
#
# Env: WASI_BUILD (build root, default /tmp/wasi-build). Idempotent (skips done steps).
# See design_docs/code_interpreter_wasm_numpy_build.md §3 for the full annotated recipe.
set -euo pipefail
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$WASI_BUILD"
cd "$WASI_BUILD"
ARCH="$(uname -m)"; [ "$ARCH" = "aarch64" ] && ARCH=arm64
OS="$(uname -s | sed -e 's/Darwin/macos/' -e 's/Linux/linux/')"

# --- wasi-sdk-27 (guard on bin/clang: a cached partial extraction must not be trusted) ---
if [ ! -x wasi-sdk/bin/clang ]; then
  rm -rf wasi-sdk
  echo ">>> downloading wasi-sdk-27"
  curl -fL --retry 3 --retry-all-errors "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-27/wasi-sdk-27.0-${ARCH}-${OS}.tar.gz" \
    -o wasi-sdk.tar.gz
  tar xf wasi-sdk.tar.gz && mv "wasi-sdk-27.0-${ARCH}-${OS}" wasi-sdk && rm wasi-sdk.tar.gz
else
  echo ">>> wasi-sdk present"
fi

# --- dicej/cpython fork (fetch by BRANCH; raw-SHA shallow fetch is refused -- Trap #3) ---
if [ ! -d cpython-src ]; then
  echo ">>> cloning dicej/cpython @ v3.14.0-wasi-sdk-27"
  git clone --depth 1 --branch v3.14.0-wasi-sdk-27 https://github.com/dicej/cpython cpython-src
else
  echo ">>> cpython-src present"
fi

# --- native host CPython 3.14 ---
if [ ! -x cpython-host/install/bin/python3.14 ]; then
  echo ">>> building native host CPython 3.14"
  mkdir -p cpython-host && cd cpython-host
  ../cpython-src/configure --prefix="$WASI_BUILD/cpython-host/install" --without-ensurepip -C
  make -j"$(nproc)"
  make install
  cd "$WASI_BUILD"
else
  echo ">>> host CPython present"
fi

# --- wasm CPython 3.14 (CROSS_PREFIX) ---
if [ ! -f cpython-wasi/install/lib/libpython3.14.a ]; then
  echo ">>> cross-compiling wasm CPython 3.14"
  mkdir -p cpython-wasi && cd cpython-wasi
  WASI_SDK_PATH="$WASI_BUILD/wasi-sdk" \
  CONFIG_SITE="$WASI_BUILD/cpython-src/Tools/wasm/wasi/config.site-wasm32-wasi" \
  CFLAGS=-fPIC \
  "$WASI_BUILD/cpython-src/Tools/wasm/wasi-env" \
  "$WASI_BUILD/cpython-src/configure" -C \
    --host=wasm32-unknown-wasip2 \
    --build="$("$WASI_BUILD/cpython-src/config.guess")" \
    --with-build-python="$WASI_BUILD/cpython-host/install/bin/python3.14" \
    --prefix="$WASI_BUILD/cpython-wasi/install" \
    --enable-wasm-dynamic-linking \
    --disable-ipv6 \
    --disable-test-modules
  make build_all install -j"$(nproc)"
  cd "$WASI_BUILD"
else
  echo ">>> wasm CPython present"
fi

# --- libpython3.14.so (CPython's wasm build only emits .a; link the shared lib by hand) ---
CP="$WASI_BUILD/cpython-wasi/install"
if [ ! -f "$CP/lib/libpython3.14.so" ]; then
  echo ">>> linking libpython3.14.so"
  "$WASI_BUILD/wasi-sdk/bin/clang" --target=wasm32-unknown-wasip2 -shared -o "$CP/lib/libpython3.14.so" \
    -Wl,--whole-archive "$CP/lib/libpython3.14.a" -Wl,--no-whole-archive \
    "$WASI_BUILD/cpython-wasi/Modules/_hacl/libHacl_HMAC.a" \
    "$WASI_BUILD/cpython-wasi/Modules/_hacl/libHacl_Hash_BLAKE2.a" \
    "$WASI_BUILD/cpython-wasi/Modules/_hacl/libHacl_Hash_MD5.a" \
    "$WASI_BUILD/cpython-wasi/Modules/_hacl/libHacl_Hash_SHA1.a" \
    "$WASI_BUILD/cpython-wasi/Modules/_hacl/libHacl_Hash_SHA2.a" \
    "$WASI_BUILD/cpython-wasi/Modules/_hacl/libHacl_Hash_SHA3.a" \
    "$WASI_BUILD/cpython-wasi/Modules/_decimal/libmpdec/libmpdec.a" \
    "$WASI_BUILD/cpython-wasi/Modules/expat/libexpat.a" \
    -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks -ldl
else
  echo ">>> libpython3.14.so present"
fi

# --- cross-python.sh (from template) ---
echo ">>> generating cross-python.sh"
sed "s|@WASI_BUILD@|$WASI_BUILD|g" "$HERE/cross-python.sh.in" > "$WASI_BUILD/cross-python.sh"
chmod +x "$WASI_BUILD/cross-python.sh"

# --- shared build venv with cython (numpy meson + pandas cythonize both need it) ---
if [ ! -x "$WASI_BUILD/build-venv/bin/cython" ]; then
  echo ">>> creating build venv with cython"
  "$WASI_BUILD/cpython-host/install/bin/python3.14" -m venv --without-pip "$WASI_BUILD/build-venv"
  curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$WASI_BUILD/get-pip.py"
  "$WASI_BUILD/build-venv/bin/python" "$WASI_BUILD/get-pip.py"
  "$WASI_BUILD/build-venv/bin/pip" install -q "cython>=3.0.6" setuptools ninja
else
  echo ">>> build venv present"
fi

echo "=== Stage 1 done ==="
"$WASI_BUILD/cross-python.sh" -c "import sysconfig; print('cross-python include:', sysconfig.get_path('include'), '| SIZEOF_VOID_P:', sysconfig.get_config_var('SIZEOF_VOID_P'))"
