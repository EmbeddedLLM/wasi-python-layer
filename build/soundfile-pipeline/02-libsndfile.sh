#!/bin/bash
# Stage 2: cross-compile libsndfile 1.2.2 for wasm32-wasip2 (static, -fPIC).
# Internal codecs only (WAV/AIFF/AU/RAW/W64/RF64/...): ENABLE_EXTERNAL_LIBS=OFF
# skips FLAC/OGG/Vorbis/Opus — those are the v2 milestone (external libs).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
SF_BUILD="$WASI_BUILD/libsndfile-build"
SF_VER="1.2.2"
SF_URL="https://github.com/libsndfile/libsndfile/releases/download/${SF_VER}/libsndfile-${SF_VER}.tar.xz"

# --- toolchain file (mirrors matplotlib-pipeline 02-native-deps.sh) ---
mkdir -p "$SF_BUILD"
cat > "$SF_BUILD/wasm32-toolchain.cmake" << TCEOF
set(CMAKE_SYSTEM_NAME WASI)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(WASI_SDK_PATH "$WASI_SDK")
set(CMAKE_C_COMPILER "\${WASI_SDK_PATH}/bin/clang")
set(CMAKE_C_COMPILER_TARGET wasm32-wasip2)
set(CMAKE_CXX_COMPILER "\${WASI_SDK_PATH}/bin/clang++")
set(CMAKE_CXX_COMPILER_TARGET wasm32-wasip2)
set(CMAKE_AR "\${WASI_SDK_PATH}/bin/llvm-ar")
set(CMAKE_RANLIB "\${WASI_SDK_PATH}/bin/llvm-ranlib")
set(CMAKE_SYSROOT "\${WASI_SDK_PATH}/share/wasi-sysroot")
set(CMAKE_C_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
TCEOF

# --- fetch + extract ---
if [ ! -d "$SF_BUILD/libsndfile-$SF_VER" ]; then
    echo ">>> Downloading libsndfile $SF_VER..."
    curl -sL "$SF_URL" -o "$SF_BUILD/libsndfile-$SF_VER.tar.xz"
    tar xJf "$SF_BUILD/libsndfile-$SF_VER.tar.xz" -C "$SF_BUILD"
fi

# --- configure + build (static, PIC — PIC is mandatory: the extension .so is
#     linked as a shared library and wasm-ld rejects non-PIC relocations) ---
echo ">>> Configuring libsndfile (static, internal codecs)..."
"$WASI_BUILD/build-venv/bin/cmake" -S "$SF_BUILD/libsndfile-$SF_VER" \
    -B "$SF_BUILD/build" \
    -DCMAKE_TOOLCHAIN_FILE="$SF_BUILD/wasm32-toolchain.cmake" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$SF_BUILD/install" \
    -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DENABLE_EXPERIMENTAL=OFF \
    -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    -DBUILD_REGTEST=OFF -DBUILD_SHARED_LIBS=OFF

"$WASI_BUILD/build-venv/bin/cmake" --build "$SF_BUILD/build" -j"$(nproc)"
"$WASI_BUILD/build-venv/bin/cmake" --install "$SF_BUILD/build"

echo ">>> libsndfile artifacts:"
ls -la "$SF_BUILD/install/lib/libsndfile.a"
