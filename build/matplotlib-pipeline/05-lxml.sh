#!/bin/bash
# Stage 5: cross-compile lxml 6.0.0 (libxml2 + libxslt + pre-generated Cython extensions).
set -euo pipefail
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
MPL_BUILD="$WASI_BUILD/matplotlib-build"
WASI_SDK="$WASI_BUILD/wasi-sdk"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
CMAKE="$WASI_BUILD/build-venv/bin/cmake"
NINJA="$WASI_BUILD/build-venv/bin/ninja"
STUBS="$MPL_BUILD/wasi_stubs.o"
FAKE="-isystem $MPL_BUILD/fake-headers"
cd "$MPL_BUILD"

dl() { [ -f "$2" ] || { echo "  [download] $2"; curl -sL "$1" -o "$2"; }; }
echo ">>> Downloading lxml + libxml2 + libxslt..."
dl "https://files.pythonhosted.org/packages/source/l/lxml/lxml-6.0.0.tar.gz" lxml-6.0.0.tar.gz
dl "https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.3.tar.xz" libxml2-2.14.3.tar.xz
dl "https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz" libxslt-1.1.43.tar.xz
for f in lxml-6.0.0.tar.gz libxml2-2.14.3.tar.xz libxslt-1.1.43.tar.xz; do
    d="${f%.tar.*}"; [ -d "$d" ] || tar xf "$f"
done

# Ensure dup() stub
if ! grep -q "int dup(" "$MPL_BUILD/wasi_stubs.c" 2>/dev/null; then
    printf '\nint dup(int fd) { (void)fd; return -1; }\n' >> "$MPL_BUILD/wasi_stubs.c"
    $WASI_SDK/bin/clang --target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot \
        -O2 -fPIC -c "$MPL_BUILD/wasi_stubs.c" -o "$STUBS"
fi

echo ">>> Building libxml2..."
if [ ! -f "$MPL_BUILD/libxml2-install/lib/libxml2.a" ]; then
    cd "$MPL_BUILD/libxml2-2.14.3"; rm -rf build-wasm; mkdir build-wasm; cd build-wasm
    $CMAKE .. -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
        -DCMAKE_TOOLCHAIN_FILE="$MPL_BUILD/wasm32-toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ICONV=OFF \
        -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
        -DLIBXML2_WITH_PYTHON=OFF -DCMAKE_C_FLAGS="-Wno-implicit-function-declaration" \
        -DCMAKE_INSTALL_PREFIX="$MPL_BUILD/libxml2-install" >/dev/null
    $CMAKE --build . -j$(nproc) >/dev/null && $CMAKE --install . >/dev/null
fi

echo ">>> Building libxslt..."
if [ ! -f "$MPL_BUILD/libxslt-install/lib/libxslt.a" ]; then
    cd "$MPL_BUILD/libxslt-1.1.43"; rm -rf build-wasm; mkdir build-wasm; cd build-wasm
    $CMAKE .. -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
        -DCMAKE_TOOLCHAIN_FILE="$MPL_BUILD/wasm32-toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DLIBXSLT_WITH_PYTHON=OFF -DLIBXSLT_WITH_TESTS=OFF -DLIBXSLT_WITH_PROGRAMS=OFF \
        -DLIBXSLT_WITH_CRYPTO=OFF -DLIBXSLT_WITH_MODULES=OFF \
        -DCMAKE_C_FLAGS="-Wno-implicit-function-declaration" \
        -DCMAKE_PREFIX_PATH="$MPL_BUILD/libxml2-install" \
        -DCMAKE_INSTALL_PREFIX="$MPL_BUILD/libxslt-install" >/dev/null
    $CMAKE --build . -j$(nproc) >/dev/null && $CMAKE --install . >/dev/null
fi

echo ">>> Building lxml extensions..."
LXML_SRC="$MPL_BUILD/lxml-6.0.0/src/lxml"
XML2_INC="$MPL_BUILD/libxml2-install/include/libxml2"
XSLT_INC="$MPL_BUILD/libxslt-install/include"
mkdir -p "$MPL_BUILD/lxml-ext"
CF="--target=wasm32-wasip2 --sysroot=$WASI_SDK/share/wasi-sysroot -O2 -fPIC $FAKE"
PI="-I$CROSS_PREFIX/include/python3.14 -I$LXML_SRC -I$LXML_SRC/includes -I$XML2_INC -I$XSLT_INC"
LF="-shared -fuse-ld=lld -Wl,--unresolved-symbols=import-dynamic $CROSS_PREFIX/lib/libpython3.14.so $STUBS"
LIBS="$MPL_BUILD/libxml2-install/lib/libxml2.a $MPL_BUILD/libxslt-install/lib/libxslt.a $MPL_BUILD/libxslt-install/lib/libexslt.a"

for ext in _elementpath builder; do
    [ -f "$MPL_BUILD/lxml-ext/$ext.so" ] && continue
    echo "  [$ext]"
    $WASI_SDK/bin/clang $CF -I$CROSS_PREFIX/include/python3.14 -I$LXML_SRC \
        $LF "$LXML_SRC/$ext.c" -o "$MPL_BUILD/lxml-ext/$ext.so" 2>&1 | grep -i error || true
done
for ext in etree objectify sax; do
    [ -f "$MPL_BUILD/lxml-ext/$ext.so" ] && continue
    echo "  [$ext]"
    $WASI_SDK/bin/clang $CF $PI $LF $LIBS "$LXML_SRC/$ext.c" \
        -o "$MPL_BUILD/lxml-ext/$ext.so" 2>&1 | grep -i error || true
done
echo ">>> lxml done: $(ls "$MPL_BUILD/lxml-ext/"*.so | wc -l) extensions"
