#!/bin/bash
# Stage 8-9 / M9: meson configure SciPy 1.18.0 for wasm32-wasip2.
# - patches the installed openblas.pc to expose -lf2c (the f2c-converted
#   LAPACK needs it; Stage 9)
# - meson setup with the scipy cross file (Stage 8) + the LP64 BLAS options
# - no fortran (ODR excluded via -D_without-fortran)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
export WASI_SDK_PATH="${WASI_SDK_PATH:-$WASI_BUILD/wasi-sdk}"
SRC="$WASI_BUILD/scipy-1.18.0"
DEPS="$WASI_BUILD/scipy-build/deps"
NUPY="$WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages"

test -f "$SRC/meson.build" || { echo "[scipy-cross] run 07-scipy-prep.sh first" >&2; exit 1; }
test -f "$NUPY/numpy/_core/lib/pkgconfig/numpy.pc" || {
  echo "[scipy-cross] numpy-wasi install missing numpy.pc — run the numpy pipeline" >&2; exit 1; }

# ── Stage 9: openblas.pc gains -lf2c ──────────────────────────────────────
PC="$DEPS/lib/pkgconfig/openblas.pc"
test -f "$PC" || { echo "[scipy-cross] missing $PC — run 02-openblas.sh" >&2; exit 1; }
if ! grep -q '\-lf2c' "$PC"; then
  sed -i 's@^Libs.private:.*@Libs.private: -lf2c ${extralib}@' "$PC"
  echo "[scipy-cross] openblas.pc: added -lf2c to Libs.private"
fi
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$NUPY/numpy/_core/lib/pkgconfig"
# Neutralize a poisoned PKG_CONFIG_PATH: GitHub's setup-python exports one
# pointing at the hostedtoolcache, whose python3.pc makes meson's cython
# sanity check resolve the NATIVE python3 dep (host paths, no include) and
# fail with 'Python.h not found' in sanity_check_for_cython.c — while a clean
# env falls back to cross-python.sh and passes. The scipy deps come via
# PKG_CONFIG_LIBDIR (openblas/f2c), so PKG_CONFIG_PATH must be empty here.
unset PKG_CONFIG_PATH || true

# ── sjlj stub (setjmp/longjmp shim, see sjlj-shim/setjmp.h) ───────────────
"$WASI_SDK_PATH/bin/clang" --target=wasm32-wasip2 \
  --sysroot="$WASI_SDK_PATH/share/wasi-sysroot" -fPIC \
  -I "$HERE/sjlj-shim" -c "$HERE/setjmp_stub.c" -o "$HERE/setjmp_stub.o"

# ── C++ EH ABI stub (__cxa_* / _Unwind_* / pthread_atfork) ────────────────
"$WASI_SDK_PATH/bin/clang" --target=wasm32-wasip2 \
  --sysroot="$WASI_SDK_PATH/share/wasi-sysroot" -fPIC \
  -c "$HERE/cxx_eh_stub.c" -o "$HERE/cxx_eh_stub.o"

# ── meson clike.py: wasm-ld rejects -Wl,--start-group (pandas pipeline
#    patch, applied to the shared build-venv meson — idempotent) ───────────
MESON_ROOT="$WASI_BUILD/build-venv/lib/python3.14/site-packages"
if [ -f "$MESON_ROOT/mesonbuild/compilers/mixins/clike.py" ] \
   && ! grep -q "_target_cpu != 'wasm32'" "$MESON_ROOT/mesonbuild/compilers/mixins/clike.py"; then
  bash "$HERE/../pandas-pipeline/patches/patch-meson-clike.sh" "$MESON_ROOT"
fi

# ── scipy source patches (ctypes guards, cython_lapack ABI, fft/stats
#    boundaries) — applied to the extracted source, idempotent ─────────────
bash "$HERE/patches/patch-scipy-src.sh" "$SRC"

# ── build env (numpy-wasi C-API for the introspection, wasi compilers) ─────
export PATH="$HERE:$WASI_BUILD/build-venv/bin:$PATH"
export CC="$WASI_SDK_PATH/bin/clang"
export CXX="$WASI_SDK_PATH/bin/clang++"
export PYTHONPATH="$HERE/numpy-stub${PYTHONPATH:+:$PYTHONPATH}:$NUPY"
export LDFLAGS="--target=wasm32-wasip2 -shared"

# ── cross file: GENERATED at runtime (a committed copy baked the local
#    checkout path in c_link_args/cpp_link_args/-I sjlj-shim and broke CI,
#    whose checkout lives elsewhere). All paths interpolated here. ─────────
CROSS_INI="$WASI_BUILD/scipy-build/scipy-cross.ini"
cat > "$CROSS_INI" <<EOF
[binaries]
c = '$WASI_SDK_PATH/bin/clang'
cpp = '$WASI_SDK_PATH/bin/clang++'
ar = '$WASI_SDK_PATH/bin/llvm-ar'
strip = '$WASI_SDK_PATH/bin/llvm-strip'
python = '$WASI_BUILD/cross-python.sh'
pkg-config = '/usr/bin/pkg-config'

[built-in options]
c_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK_PATH/share/wasi-sysroot', '-fPIC', '-O3', '-msimd128', '-D__EMSCRIPTEN__=1', '-Wcast-function-type-strict', '-D_WASI_EMULATED_SIGNAL', '-DFE_UPWARD=0x800', '-DFE_DOWNWARD=0x400', '-mno-atomics', '-I$HERE/sjlj-shim']
c_link_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK_PATH/share/wasi-sysroot', '-shared', '-fuse-ld=lld', '-Wl,--experimental-pic', '-Wl,--unresolved-symbols=import-dynamic', '-L$DEPS/lib', '-lwasi-emulated-signal', '$HERE/setjmp_stub.o', '-lc++', '$HERE/cxx_eh_stub.o']
cpp_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK_PATH/share/wasi-sysroot', '-fPIC', '-O3', '-msimd128', '-DDUCC0_NO_LOWLEVEL_THREADING', '-D__EMSCRIPTEN__=1', '-Wcast-function-type-strict', '-D_WASI_EMULATED_SIGNAL', '-DFE_UPWARD=0x800', '-DFE_DOWNWARD=0x400', '-mno-atomics', '-I$HERE/sjlj-shim']
cpp_link_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK_PATH/share/wasi-sysroot', '-shared', '-fuse-ld=lld', '-Wl,--experimental-pic', '-Wl,--unresolved-symbols=import-dynamic', '-L$DEPS/lib', '-lwasi-emulated-signal', '$HERE/setjmp_stub.o', '-lc++', '$HERE/cxx_eh_stub.o']

[host_machine]
system = 'wasi'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'

buildtype = 'release'
[properties]
needs_exe_wrapper = true
sys_root = '$WASI_SDK_PATH/share/wasi-sysroot'
longdouble_format = 'IEEE_QUAD_LE'
EOF

cd "$SRC"
echo "[scipy-cross] meson setup (cross file: $CROSS_INI)"
# Re-runable: a configured build dir gets --reconfigure (re-applies the
# current cross file + options) instead of failing with "already configured".
SETUP_EXTRA=""
[ -f build/build.ninja ] && SETUP_EXTRA="--reconfigure"
meson setup build $SETUP_EXTRA \
  --cross-file "$CROSS_INI" \
  -Dblas=openblas -Dlapack=openblas -Duse-ilp64=false \
  -Dcython-blas-abi=lp64 -Duse-pythran=false -D_without-fortran=true \
  > "$WASI_BUILD/scipy-build/meson-setup.log" 2>&1 || {
    echo "[scipy-cross] meson setup FAILED (log: $WASI_BUILD/scipy-build/meson-setup.log)" >&2
    tail -40 "$WASI_BUILD/scipy-build/meson-setup.log" >&2
    exit 1
  }
echo "[scipy-cross] meson setup OK"
# informational; pipefail-safe (no head — grep output is short and must not
# SIGPIPE-kill the stage under set -o pipefail; exit 141 was a real bug)
meson configure build | grep -E "blas|lapack|ilp64|pythran|fortran" || true
