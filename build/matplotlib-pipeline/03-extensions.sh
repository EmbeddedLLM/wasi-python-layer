#!/bin/bash
# Stage 3: build all 9 C/C++ extensions for matplotlib + deps.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
MPL_BUILD="$WASI_BUILD/matplotlib-build"
WASI_SDK="$WASI_BUILD/wasi-sdk"
MPL_SRC="$MPL_BUILD/matplotlib-3.11.1"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
VENV="$WASI_BUILD/build-venv"
PYBIND11_INC="$($VENV/bin/python -c 'import pybind11; print(pybind11.get_include())')"
CPPY_INC="$($VENV/bin/python -c 'import cppy; print(cppy.get_include())')"
AGG_INC="$MPL_SRC/extern/agg24-svn/include"
FT_INC="$MPL_BUILD/freetype-install/include/freetype2"
STUBS="$MPL_BUILD/wasi_stubs.o"
FAKE="-isystem $MPL_BUILD/fake-headers"

# Apply source patches (idempotent)
echo ">>> Applying patches..."
for patch in "$HERE"/patches/*.sh; do
    [ -f "$patch" ] && bash "$patch" "$MPL_SRC" "$MPL_BUILD"
done

CF="--target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot -std=c++17 -O2 -fPIC -fvisibility=hidden $FAKE"
PI="-I$PYBIND11_INC -I$CROSS_PREFIX/include/python3.14 -I$MPL_SRC/src -I$AGG_INC"
LF="-shared -fuse-ld=lld -Wl,--unresolved-symbols=import-dynamic $CROSS_PREFIX/lib/libpython3.14.so $STUBS"

mkdir -p "$MPL_BUILD/ext"

build_ext() {
    local name="$1"; shift
    echo "  [$name]"
    $WASI_SDK/bin/clang++ $CF "$@" $LF -o "$MPL_BUILD/ext/$name.so" 2>&1 | grep -i error || true
}

echo ">>> Building matplotlib extensions..."

# 1-5: matplotlib core (pybind11 + agg)
build_ext _c_internal_utils $PI \
    "$MPL_SRC/src/_c_internal_utils.cpp"

build_ext _path $PI "$MPL_BUILD/agg/libagg.a" \
    "$MPL_SRC/src/_path_wrapper.cpp"

build_ext _image $PI "$MPL_BUILD/agg/libagg.a" \
    "$MPL_SRC/src/_image_wrapper.cpp" "$MPL_SRC/src/py_converters.cpp"

build_ext _tri $PI \
    "$MPL_SRC/src/tri/_tri.cpp" "$MPL_SRC/src/tri/_tri_wrapper.cpp"

build_ext _backend_agg $PI "$MPL_BUILD/agg/libagg.a" \
    "$MPL_SRC/src/_backend_agg.cpp" "$MPL_SRC/src/_backend_agg_wrapper.cpp"

# 6: qhull
build_ext _qhull $PI -I"$MPL_BUILD/qhull-8.0.2/src" -DMPL_DEVNULL='"/dev/null"' \
    "$MPL_BUILD/qhull-objs/libqhull_r.a" -lwasi-emulated-process-clocks \
    "$MPL_SRC/src/_qhull_wrapper.cpp"

# 7: ft2font (freetype + raqm)
build_ext ft2font $PI -I"$FT_INC" -I"$MPL_BUILD/raqm-stub" -DFREETYPE_BUILD_TYPE='"local"' \
    "$MPL_BUILD/freetype-install/lib/libfreetype.a" "$MPL_BUILD/raqm-stub/libraqm.a" \
    "$MPL_SRC/src/ft2font.cpp" "$MPL_SRC/src/ft2font_wrapper.cpp"

# 8: contourpy
CP_SRC="$MPL_BUILD/contourpy-1.3.2/src"
echo "  [_contourpy]"
$WASI_SDK/bin/clang++ --target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot \
    -std=c++17 -O2 -fPIC -fvisibility=hidden -DCONTOURPY_VERSION=1.3.2 \
    -I"$PYBIND11_INC" -I"$CROSS_PREFIX/include/python3.14" -I"$CP_SRC" \
    $LF \
    "$CP_SRC"/chunk_local.cpp "$CP_SRC"/contour_generator.cpp "$CP_SRC"/converter.cpp \
    "$CP_SRC"/fill_type.cpp "$CP_SRC"/line_type.cpp "$CP_SRC"/mpl2005_original.cpp \
    "$CP_SRC"/mpl2005.cpp "$CP_SRC"/mpl2014.cpp "$CP_SRC"/outer_or_hole.cpp \
    "$CP_SRC"/serial.cpp "$CP_SRC"/threaded.cpp "$CP_SRC"/util.cpp \
    "$CP_SRC"/wrap.cpp "$CP_SRC"/z_interp.cpp \
    -o "$MPL_BUILD/ext/_contourpy.so" 2>&1 | grep -i error || true

# 9: kiwisolver
KW_SRC="$MPL_BUILD/kiwisolver-1.4.8"
echo "  [kiwisolver]"
$WASI_SDK/bin/clang++ --target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot \
    -std=c++17 -O2 -fPIC -fvisibility=hidden -DPY_KIWI_VERSION='"1.4.8"' \
    -I"$CPPY_INC" -I"$CROSS_PREFIX/include/python3.14" -I"$KW_SRC" -I"$KW_SRC/py/src" \
    $LF \
    "$KW_SRC"/py/src/kiwisolver.cpp "$KW_SRC"/py/src/constraint.cpp \
    "$KW_SRC"/py/src/expression.cpp "$KW_SRC"/py/src/solver.cpp \
    "$KW_SRC"/py/src/strength.cpp "$KW_SRC"/py/src/term.cpp "$KW_SRC"/py/src/variable.cpp \
    -o "$MPL_BUILD/ext/kiwisolver.so" 2>&1 | grep -i error || true

echo ">>> Extensions built:"
ls -lh "$MPL_BUILD/ext/"*.so | awk '{print "  " $NF " (" $5 ")"}'
