#!/bin/bash
# Cross-compile numpy for wasm32-wasip2 (wasi-sdk-27). Modeled on dicej/wasi-wheels numpy/build.sh.
# Run from the numpy source root. Required env: CROSS_PREFIX (wasm CPython install prefix),
# WASI_SDK_PATH (wasi-sdk root), HOST_PYTHON (a native python3.14).
# Every flag below is load-bearing — see design_docs/code_interpreter_wasm_numpy_build.md §3.5 (Traps #6-#11).
set -eou pipefail

: "${CROSS_PREFIX:?set to the wasm CPython install prefix}"
: "${WASI_SDK_PATH:?set to the wasi-sdk root}"
: "${HOST_PYTHON:?set to a native python3.14}"

ARCH_TRIPLET=_wasi_wasm32-wasi

# venv with pip. The host CPython is built --without-ensurepip, so bootstrap pip via get-pip.py.
if [ ! -x venv/bin/python ]; then
  "$HOST_PYTHON" -m venv --without-pip venv
  curl -fsSL https://bootstrap.pypa.io/get-pip.py -o venv/get-pip.py
  venv/bin/python venv/get-pip.py
  venv/bin/pip install -q cython==3.0.12 setuptools==71.1.0
fi
. venv/bin/activate

export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"
export PYTHONPATH=$CROSS_PREFIX/lib/python3.14
# Trap #6: -D__EMSCRIPTEN__=1 (numpy has no WASI port; reuse the emscripten path).
# Trap #7: -DNPY_NO_SIGNAL (WASI has no signals).
export CFLAGS="--target=wasm32-wasip2 -I${CROSS_PREFIX}/include/python3.14 -D__EMSCRIPTEN__=1 -DNPY_NO_SIGNAL"
export CXXFLAGS="--target=wasm32-wasip2 -I${CROSS_PREFIX}/include/python3.14"
# Trap #10: LDSHARED=clang, RANLIB=true (wasm ar needs no ranlib).
export LDSHARED=${CC}
export AR="${WASI_SDK_PATH}/bin/ar"
export RANLIB=true
export LDFLAGS="--target=wasm32-wasip2 -shared ${CROSS_PREFIX}/lib/libpython3.14.so"
# Trap #9: point setuptools at the CROSS sysconfigdata, not the host's.
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_${ARCH_TRIPLET}
# Trap #8: no BLAS/LAPACK/SVML in wasm -> pure-C numpy.
export NPY_DISABLE_SVML=1
export NPY_BLAS_ORDER=
export NPY_LAPACK_ORDER=

# numpy 1.26/2.0-dev uses setup.py (numpy 2.x-final switched to meson — Trap #11).
python setup.py build --disable-optimization -j "$(nproc)"
