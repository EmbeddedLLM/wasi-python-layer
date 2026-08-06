#!/bin/bash
# Stage 2: build numpy 2.5.1 for wasm32-wasip2 via meson (numpy 2.x is meson-python).
# Crosses the eight meson cross-compilation walls -- see
# design_docs/code_interpreter_wasm_numpy251_meson_build.md for the full annotated account.
#
# Env: WASI_BUILD (default /tmp/wasi-build), NUMPY_VERSION (default 2.5.1).
# Produces: $WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages/numpy
set -euo pipefail
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
NUMPY_VERSION="${NUMPY_VERSION:-2.5.1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="$WASI_BUILD/wasi-sdk"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
CROSS_PY="$WASI_BUILD/cross-python.sh"
NB="$WASI_BUILD/numpy251"
mkdir -p "$NB"
export PATH="$WASI_BUILD/build-venv/bin:$PATH"   # meson needs cython

# --- fetch numpy sdist (marker-verified: a cached partial extraction must not
# be trusted — the umath codegen needs numpy/_core/code_generators) ---
if [ ! -f "$NB/numpy-$NUMPY_VERSION/numpy/_core/code_generators/generate_umath.py" ]; then
  rm -rf "$NB/numpy-$NUMPY_VERSION"
  echo ">>> downloading numpy $NUMPY_VERSION sdist"
  cd "$NB"
  URL="$(curl -fsSL "https://pypi.org/pypi/numpy/$NUMPY_VERSION/json" \
    | python3 -c "import json,sys; print([u['url'] for u in json.load(sys.stdin)['urls'] if u['url'].endswith('.tar.gz')][0])")"
  curl -fL --retry 5 --retry-delay 3 --retry-all-errors "$URL" -o "numpy-$NUMPY_VERSION.tar.gz"
  tar xzf "numpy-$NUMPY_VERSION.tar.gz"
fi
SRC="$NB/numpy-$NUMPY_VERSION"

# --- Wall 2: patch host pyconfig.h to wasm32 sizes ---
"$HERE/patches/patch-pyconfig-wasm32.sh" "$WASI_BUILD/cpython-host/install"
# --- Wall 7: temp_elide.c dladdr guard ---
"$HERE/patches/patch-numpy-temp-elide.sh" "$SRC"
# --- Walls 3 + 9: find_installation -> cross-python; add C++ EH stub ---
"$HERE/patches/patch-numpy-meson.sh" "$SRC" "$CROSS_PY" "$HERE/cxx_eh_stub.c"
# --- Wall 8: meson clike.py --start-group (vendored meson) ---
"$HERE/patches/patch-meson-clike.sh" "$SRC/vendored-meson/meson"

# --- the cross-file (Wall 1: -fuse-ld=lld; Wall 5: link args ONLY; Wall 6: longdouble) ---
cat > "$NB/wasi-cross.ini" <<EOF
[binaries]
c = '$SDK/bin/clang'
cpp = '$SDK/bin/clang++'
ar = '$SDK/bin/llvm-ar'
strip = '$SDK/bin/llvm-strip'
python = '$CROSS_PY'

[built-in options]
c_args = ['--target=wasm32-wasip2', '--sysroot=$SDK/share/wasi-sysroot', '-fPIC', '-D__EMSCRIPTEN__=1']
c_link_args = ['--target=wasm32-wasip2', '--sysroot=$SDK/share/wasi-sysroot', '-shared', '-fuse-ld=lld', '-Wl,--unresolved-symbols=import-dynamic']
cpp_args = ['--target=wasm32-wasip2', '--sysroot=$SDK/share/wasi-sysroot', '-fPIC', '-D__EMSCRIPTEN__=1']
cpp_link_args = ['--target=wasm32-wasip2', '--sysroot=$SDK/share/wasi-sysroot', '-shared', '-fuse-ld=lld', '-Wl,--unresolved-symbols=import-dynamic']

[host_machine]
system = 'wasi'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'

[properties]
sys_root = '$SDK/share/wasi-sysroot'
needs_exe_wrapper = true
longdouble_format = 'IEEE_QUAD_LE'
EOF

# --- build with the VENDORED meson (Wall 4: the 'features' module lives there) ---
cd "$SRC"
MESON="python3 $SRC/vendored-meson/meson/meson.py"
echo ">>> meson setup (numpy $NUMPY_VERSION)"
if [ -d build/meson-info ]; then RECONF="--reconfigure"; else RECONF=""; fi
$MESON setup $RECONF build --cross-file="$NB/wasi-cross.ini" \
  -Dallow-noblas=true -Dcpu-dispatch=none -Dcpu-baseline=none
echo ">>> meson compile"
$MESON compile -C build
echo ">>> meson install (the trailing pycompile step fails harmlessly)"
$MESON install -C build --destdir "$WASI_BUILD/numpy251-install" || true

echo "=== Stage 2 done: numpy $NUMPY_VERSION installed to $WASI_BUILD/numpy251-install ==="
find "$WASI_BUILD/numpy251-install" -name "_multiarray_umath*.so"
