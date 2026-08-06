#!/bin/bash
# Cross-compile Pillow 9.5.0 (+ zlib + libjpeg-turbo) for wasm32-wasip2 (wasi-sdk-27).
# Reuses the numpy pipeline's wasm CPython. Run in an empty work dir. Required env:
#   CROSS_PREFIX (wasm CPython install prefix), WASI_SDK_PATH (wasi-sdk root), HOST_PYTHON (native 3.14).
# Traps P1-P10: design_docs/code_interpreter_wasm_pillow_build.md. Adapted from bkmashiro/wasi-wheels.
set -eou pipefail

: "${CROSS_PREFIX:?wasm CPython install prefix}"
: "${WASI_SDK_PATH:?wasi-sdk root}"
: "${HOST_PYTHON:?native python3.14}"

WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
DEPS_PREFIX="$(pwd)/wasi-deps"
PILLOW_VERSION="9.5.0"
PILLOW_SRC="Pillow-${PILLOW_VERSION}"
TARGET=wasm32-wasip2

if [ ! -x venv/bin/python ]; then
  "$HOST_PYTHON" -m venv --without-pip venv
  curl -fsSL https://bootstrap.pypa.io/get-pip.py -o venv/get-pip.py
  venv/bin/python venv/get-pip.py
  venv/bin/pip install -q wheel setuptools cmake   # Trap P1: cmake for libjpeg-turbo
fi
. venv/bin/activate

WASI_CFLAGS="--target=$TARGET --sysroot=${WASI_SYSROOT} -fPIC"

# ── zlib ─────────────────────────────────────────────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libz.a" ]; then
  ZLIB_VERSION="1.3.1"
  [ -f "zlib-${ZLIB_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" -o "zlib-${ZLIB_VERSION}.tar.gz"
  tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
  ( cd "zlib-${ZLIB_VERSION}" && CC="${WASI_SDK_PATH}/bin/clang" CFLAGS="${WASI_CFLAGS}" ./configure --prefix="${DEPS_PREFIX}" --static && make -j"$(nproc)" && make install )
fi

# ── libjpeg-turbo (cmake; SIMD off — Trap P2) ────────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libjpeg.a" ]; then
  JPEG_VERSION="2.1.5.1"
  [ -f "libjpeg-turbo-${JPEG_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_VERSION}/libjpeg-turbo-${JPEG_VERSION}.tar.gz" -o "libjpeg-turbo-${JPEG_VERSION}.tar.gz"
  tar xzf "libjpeg-turbo-${JPEG_VERSION}.tar.gz"
  mkdir -p "libjpeg-turbo-${JPEG_VERSION}/build-wasi"
  ( cd "libjpeg-turbo-${JPEG_VERSION}/build-wasi" && cmake .. \
      -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" -DCMAKE_C_FLAGS="${WASI_CFLAGS}" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DWITH_SIMD=FALSE -DWITH_JPEG8=1 -DWITH_TURBOJPEG=FALSE \
      -DENABLE_SHARED=FALSE -DENABLE_STATIC=TRUE -DCMAKE_BUILD_TYPE=Release \
    && make -j"$(nproc)" && make install )
fi

# ── Pillow source ────────────────────────────────────────────────────────────
if [ ! -d "${PILLOW_SRC}" ]; then
  [ -f "${PILLOW_SRC}.tar.gz" ] || curl -fsSL "https://files.pythonhosted.org/packages/00/d5/4903f310765e0ff2b8e91ffe55031ac6af77d982f0156061e20a4d1a8b2d/Pillow-9.5.0.tar.gz" -o "${PILLOW_SRC}.tar.gz"
  tar xzf "${PILLOW_SRC}.tar.gz"
  # PEP 667 (py3.13+): locals() is a snapshot, so Pillow 9.5.0's get_version —
  # exec(_version.py) then `locals()["__version__"]` — KeyErrors under the
  # 3.14 host python (cold-build regression caught 2026-08-06). Redirect to
  # globals().
  python3 - << 'PYEOF'
from pathlib import Path
p = Path("Pillow-9.5.0/setup.py")
s = p.read_text()
s = s.replace('exec(compile(f.read(), version_file, "exec"))',
              'exec(compile(f.read(), version_file, "exec"), globals())')
s = s.replace('return locals()["__version__"]', 'return globals()["__version__"]')
p.write_text(s)
print("patched Pillow setup.py get_version for PEP 667")
PYEOF
fi

# ── clang wrapper: strip host -I/usr/... includes (Trap P9) ──────────────────
WRAPPER_DIR="$(pwd)/wrapper"
mkdir -p "$WRAPPER_DIR"
REAL_CLANG="${WASI_SDK_PATH}/bin/clang"; REAL_CLANGXX="${WASI_SDK_PATH}/bin/clang++"
cat > "${WRAPPER_DIR}/clang" <<'WRAPPER'
#!/bin/bash
args=()
for arg in "$@"; do
  case "$arg" in
    -I/usr/include|-I/usr/include/*|-I/usr/local/include|-I/usr/local/include/*) ;;
    *) args+=("$arg") ;;
  esac
done
exec "@REAL_CLANG@" "${args[@]}"
WRAPPER
sed -i "s|@REAL_CLANG@|${REAL_CLANG}|g" "${WRAPPER_DIR}/clang"
cp "${WRAPPER_DIR}/clang" "${WRAPPER_DIR}/clang++"
sed -i "s|${REAL_CLANG}|${REAL_CLANGXX}|g" "${WRAPPER_DIR}/clang++"
chmod +x "${WRAPPER_DIR}/clang" "${WRAPPER_DIR}/clang++"

# ── __wasi_proc_exit stub (Trap P3) ──────────────────────────────────────────
cat > "${WRAPPER_DIR}/wasi_compat.c" <<'CEOF'
__attribute__((noreturn))
void __wasi_proc_exit(int code) { __builtin_trap(); }
CEOF
"${WASI_SDK_PATH}/bin/clang" --target=$TARGET --sysroot="${WASI_SYSROOT}" -fPIC -c "${WRAPPER_DIR}/wasi_compat.c" -o "${WRAPPER_DIR}/wasi_compat.o"
"${WASI_SDK_PATH}/bin/llvm-ar" rcs "${WRAPPER_DIR}/libwasi_compat.a" "${WRAPPER_DIR}/wasi_compat.o"

# ── build Pillow ─────────────────────────────────────────────────────────────
cd "${PILLOW_SRC}"
# Jpeg.h setjmp stub (Trap P4)
python3 - <<'PYEOF'
import sys
path = "src/libImaging/Jpeg.h"; src = open(path).read()
stub = ("#ifdef __wasi__\ntypedef unsigned char jmp_buf[16];\n"
        "#ifndef setjmp\n#define setjmp(env) 0\n#endif\n"
        "#ifndef longjmp\n#define longjmp(env, val) __builtin_trap()\n#endif\n"
        "#else\n#include <setjmp.h>\n#endif\n")
patched = src.replace("#include <setjmp.h>", stub, 1)
if patched != src:
    open(path, "w").write(patched); print("patched Jpeg.h setjmp")
PYEOF

export CC="${WRAPPER_DIR}/clang" CXX="${WRAPPER_DIR}/clang++"
export AR="${WASI_SDK_PATH}/bin/llvm-ar" RANLIB="${WASI_SDK_PATH}/bin/llvm-ranlib" STRIP="${WASI_SDK_PATH}/bin/llvm-strip"
export CFLAGS="--target=$TARGET --sysroot=${WASI_SYSROOT} -isystem ${WASI_SYSROOT}/include -isystem ${WASI_SYSROOT}/include/$TARGET -I${CROSS_PREFIX}/include/python3.14 -I${DEPS_PREFIX}/include -D__EMSCRIPTEN__=1 -fPIC"
export LDFLAGS="--target=$TARGET --sysroot=${WASI_SYSROOT} -L${DEPS_PREFIX}/lib -L${WASI_SYSROOT}/lib/$TARGET -L${CROSS_PREFIX}/lib -L${WRAPPER_DIR} ${CROSS_PREFIX}/lib/libpython3.14.so -shared -Wl,--experimental-pic -Wl,--unresolved-symbols=import-dynamic -lwasi_compat"
export LDSHARED="${WRAPPER_DIR}/clang"
export ZLIB_ROOT="${DEPS_PREFIX}" JPEG_ROOT="${DEPS_PREFIX}" DISABLE_PLATFORM_GUESSING=1
export PYTHONPATH="${CROSS_PREFIX}/lib/python3.14"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi

# Trap P7: build_ext emits only .so; bdist_wheel + unpack gives the full PIL (.py + .so).
python3 setup.py build_ext --plat-name $TARGET
python3 setup.py bdist_wheel --plat-name $TARGET
wheel unpack --dest build dist/[Pp]illow-*.whl
echo "PILLOW_DONE: $(ls build/*/PIL/__init__.py)"
