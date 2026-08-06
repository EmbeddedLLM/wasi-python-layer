#!/bin/bash
# Stage 2: cross-compile native dependencies (agg, freetype, qhull, raqm stub).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
MPL_BUILD="$WASI_BUILD/matplotlib-build"
WASI_SDK="$WASI_BUILD/wasi-sdk"
MPL_SRC="$MPL_BUILD/matplotlib-3.11.1"
CMAKE="$WASI_BUILD/build-venv/bin/cmake"
NINJA="$WASI_BUILD/build-venv/bin/ninja"

# --- fake setjmp.h (eryx/wizer doesn't support wasm EH) ---
mkdir -p "$MPL_BUILD/fake-headers"
cat > "$MPL_BUILD/fake-headers/setjmp.h" << 'FAKEOF'
#ifndef _FAKE_SETJMP_H
#define _FAKE_SETJMP_H
typedef struct { int _dummy[16]; } jmp_buf[1];
typedef jmp_buf sigjmp_buf;
static inline int setjmp(jmp_buf env) { (void)env; return 0; }
static inline int sigsetjmp(sigjmp_buf env, int s) { (void)env; (void)s; return 0; }
_Noreturn static inline void longjmp(jmp_buf env, int v) { (void)env; (void)v; __builtin_trap(); }
_Noreturn static inline void siglongjmp(sigjmp_buf env, int v) { (void)env; (void)v; __builtin_trap(); }
#endif
FAKEOF

# --- C++ EH stubs ---
cp "$HERE/wasi_stubs.c" "$MPL_BUILD/wasi_stubs.c"
$WASI_SDK/bin/clang --target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot \
    -O2 -fPIC -c "$MPL_BUILD/wasi_stubs.c" -o "$MPL_BUILD/wasi_stubs.o"

# --- cmake toolchain file ---
cat > "$MPL_BUILD/wasm32-toolchain.cmake" << TCEOF
set(CMAKE_SYSTEM_NAME WASI)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(WASI_SDK_PATH "$WASI_SDK")
set(CMAKE_C_COMPILER "\${WASI_SDK_PATH}/bin/clang")
set(CMAKE_CXX_COMPILER "\${WASI_SDK_PATH}/bin/clang++")
set(CMAKE_AR "\${WASI_SDK_PATH}/bin/llvm-ar")
set(CMAKE_RANLIB "\${WASI_SDK_PATH}/bin/llvm-ranlib")
set(CMAKE_C_COMPILER_TARGET "wasm32-wasip2")
set(CMAKE_CXX_COMPILER_TARGET "wasm32-wasip2")
set(CMAKE_SYSROOT "\${WASI_SDK_PATH}/share/wasi-sysroot")
set(CMAKE_C_FLAGS_INIT "-fuse-ld=lld -isystem $MPL_BUILD/fake-headers")
set(CMAKE_CXX_FLAGS_INIT "-fuse-ld=lld -isystem $MPL_BUILD/fake-headers -fno-exceptions")
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
TCEOF

# --- 1. agg (bundled in matplotlib, 8 cpp files) ---
echo ">>> Building agg..."
AGG_SRC="$MPL_SRC/extern/agg24-svn/src"
AGG_INC="$MPL_SRC/extern/agg24-svn/include"
mkdir -p "$MPL_BUILD/agg"
for f in agg_bezier_arc agg_curves agg_image_filters agg_trans_affine \
         agg_vcgen_contour agg_vcgen_dash agg_vcgen_stroke agg_vpgen_segmentator; do
    $WASI_SDK/bin/clang++ --target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot \
        -std=c++17 -O2 -fPIC -fno-exceptions -fvisibility-inlines-hidden \
        -I"$AGG_INC" -c "$AGG_SRC/$f.cpp" -o "$MPL_BUILD/agg/$f.o"
done
$WASI_SDK/bin/llvm-ar rcs "$MPL_BUILD/agg/libagg.a" "$MPL_BUILD/agg/"*.o
echo "  agg: $(du -h "$MPL_BUILD/agg/libagg.a" | cut -f1)"

# --- 2. freetype 2.14.3 (cmake) ---
echo ">>> Building freetype..."
if [ ! -f "$MPL_BUILD/freetype-install/lib/libfreetype.a" ]; then
    cd "$MPL_BUILD/freetype-2.14.3"
    rm -rf build-wasm && mkdir build-wasm && cd build-wasm
    $CMAKE .. -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
        -DCMAKE_TOOLCHAIN_FILE="$MPL_BUILD/wasm32-toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
        -DFT_DISABLE_PNG=ON -DFT_DISABLE_ZLIB=ON \
        -DCMAKE_INSTALL_PREFIX="$MPL_BUILD/freetype-install" >/dev/null
    $CMAKE --build . -j$(nproc) >/dev/null
    $CMAKE --install . >/dev/null
fi
echo "  freetype: $(du -h "$MPL_BUILD/freetype-install/lib/libfreetype.a" | cut -f1)"

# --- 3. qhull_r 8.0.2 (direct clang) ---
echo ">>> Building qhull_r..."
QHULL_SRC="$MPL_BUILD/qhull-8.0.2/src/libqhull_r"
mkdir -p "$MPL_BUILD/qhull-objs"
for f in "$QHULL_SRC/"*.c; do
    base=$(basename "$f" .c)
    $WASI_SDK/bin/clang --target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot \
        -O2 -fPIC -isystem "$MPL_BUILD/fake-headers" \
        -D_WASI_EMULATED_PROCESS_CLOCKS -Wno-deprecated-declarations \
        -I"$MPL_BUILD/qhull-8.0.2/src" \
        -c "$f" -o "$MPL_BUILD/qhull-objs/$base.o"
done
$WASI_SDK/bin/llvm-ar rcs "$MPL_BUILD/qhull-objs/libqhull_r.a" "$MPL_BUILD/qhull-objs/"*.o
echo "  qhull_r: $(du -h "$MPL_BUILD/qhull-objs/libqhull_r.a" | cut -f1)"

# --- 4. raqm stub (minimal LTR layout) ---
echo ">>> Building raqm stub..."
cp "$HERE/raqm_stub.c" "$MPL_BUILD/raqm_stub.c"
cp "$HERE/raqm.h" "$MPL_BUILD/raqm.h" 2>/dev/null || true
cp "$HERE/raqm-version.h" "$MPL_BUILD/raqm-version.h" 2>/dev/null || true
mkdir -p "$MPL_BUILD/raqm-stub"
cp "$MPL_BUILD/raqm.h" "$MPL_BUILD/raqm-stub/" 2>/dev/null || true
cp "$MPL_BUILD/raqm-version.h" "$MPL_BUILD/raqm-stub/" 2>/dev/null || true
cp "$MPL_BUILD/raqm_stub.c" "$MPL_BUILD/raqm-stub/"
$WASI_SDK/bin/clang --target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot \
    -O2 -fPIC -I"$MPL_BUILD/raqm-stub" \
    -I"$MPL_BUILD/freetype-install/include/freetype2" \
    -c "$MPL_BUILD/raqm-stub/raqm_stub.c" -o "$MPL_BUILD/raqm-stub/raqm_stub.o"
$WASI_SDK/bin/llvm-ar rcs "$MPL_BUILD/raqm-stub/libraqm.a" "$MPL_BUILD/raqm-stub/raqm_stub.o"
echo "  raqm stub: $(du -h "$MPL_BUILD/raqm-stub/libraqm.a" | cut -f1)"

echo ">>> Native deps done."
