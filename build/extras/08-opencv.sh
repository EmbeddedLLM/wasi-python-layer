#!/bin/bash
# extras/08-opencv.sh — OpenCV 4.12.0 (cv2) bespoke wasm32-wasip2 build.
#
# There is NO prebuilt cv2 for wasm32-wasip1/wasip2 anywhere (OpenCV.js is
# emscripten-only and cannot run under WASI). This builds a curated subset
# (core, imgproc, imgcodecs, objdetect, features2d, calib3d, flann) with the
# python3 bindings, from source. The cv2 module is a WASI shared library
# late-linked into the factory. Lessons (Worklog Checkpoints 6-7):
#   - cpu_set_t affinity code needs a __wasm__ exclusion (parallel.cpp).
#   - getrusage/times need -D_WASI_EMULATED_* + the emulated link libs.
#   - wasi setjmp.h forces -mllvm -wasm-enable-sjlj, whose lowering emits wasm
#     EH instructions the runtime REJECTS ("exceptions are unsupported") — the
#     sjlj flag is dropped and a setjmp.h shim + trap stub replace it.
#   - ANY try/catch in compiled code emits wasm EH instructions (also rejected);
#     the try/catch constructs are stripped from the source (throw stays — it
#     lowers to __cxa_throw, satisfied by the pandas cxx_eh_stub).
#   - CMake must NOT use CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY (it makes
#     add_library(SHARED/MODULE) fall back to `ar`) and the python3 module must
#     be in BUILD_LIST (whitelist) or it is silently skipped.
#   - The generated cv2/__init__.py bootstrap re-imports "cv2" — the host relies
#     on the cv2.abi3.so suffix trick; the wasm finder resolves back to the
#     package and recurses, so bootstrap is patched to load the extension by
#     path via importlib.util.spec_from_file_location.
#
# Usage: SITE=/path/site-packages bash 08-opencv.sh   (default $WASI_BUILD/extras-site)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
export PATH="$WASI_BUILD/build-venv/bin:$PATH"   # cmake, ninja (system cmake absent in bare containers)
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
CROSS_PY="$WASI_BUILD/cross-python.sh"
NB="$WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages"
CV_VERSION="4.12.0"
BUILD="$WASI_BUILD/opencv-build"
SRC="$WASI_BUILD/opencv-src"

mkdir -p "$BUILD"

# --- 1. source --------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    echo ">>> [extras/08] Cloning OpenCV $CV_VERSION (recursive; ~10 min)..."
    git clone --recursive --depth 1 --branch "$CV_VERSION" \
        https://github.com/opencv/opencv.git "$SRC"
fi
cd "$SRC"

# --- 2. source patches ------------------------------------------------------
echo ">>> [extras/08] Applying source patches (affinity, try/catch, ovx)..."
sed -i 's|#if defined _GNU_SOURCE \\|#if defined _GNU_SOURCE \&\& !defined(__wasm__) \\|' \
    modules/core/src/parallel.cpp
python3 - <<'PYEOF'
import re
from pathlib import Path

roots = ["modules/core/src", "modules/imgproc/src", "modules/imgcodecs/src",
         "modules/objdetect/src", "modules/features2d/src", "modules/calib3d/src", "modules/flann/src"]
skip = ("opengl", "dnn", "ocl", "cuda", "opencl", "cl_", "ts/")
stmt = re.compile(r"^\s*try\s*\{?\s*$")
catch_start = re.compile(r"^\s*catch\s*\(.*\)\s*(\{?)\s*$")
catch_sameline = re.compile(r"^(\s*)\} catch\(.*\) \{$")
oneline_catch = re.compile(r"^\s*catch\s*\(.*\)\s*\{[^}]*\}\s*$")
trailing_catch = re.compile(r"^(\s*)\} catch\s*\(.*\) \{[^}]*\}\s*$")

def strip_try_catch(lines):
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if stmt.match(line):
            out.append(re.sub(r"\btry\b", "", line, count=1)); i += 1; continue
        if oneline_catch.match(line):
            i += 1; continue
        if trailing_catch.match(line):
            out.append(trailing_catch.match(line).group(1) + "}"); i += 1; continue
        m = catch_start.match(line)
        if m:
            if m.group(1):
                i += 1; depth = 1
                while i < len(lines) and depth > 0:
                    depth += lines[i].count("{") - lines[i].count("}"); i += 1
            else:
                i += 1; depth = 0
                while i < len(lines) and depth < 1:
                    depth += lines[i].count("{") - lines[i].count("}"); i += 1
                while i < len(lines) and depth > 0:
                    depth += lines[i].count("{") - lines[i].count("}"); i += 1
            continue
        m = catch_sameline.match(line)
        if m:
            out.append(m.group(1) + "}"); i += 1; depth = 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count("{") - lines[i].count("}"); i += 1
            continue
        out.append(line); i += 1
    return out

patched = 0
for r in roots:
    for p in Path(r).rglob("*"):
        if p.suffix not in (".cpp", ".hpp", ".h") or any(sk in str(p) for sk in skip):
            continue
        lines = p.read_text(errors="ignore").split("\n")
        if any(stmt.match(l) for l in lines):
            p.write_text("\n".join(strip_try_catch(lines))); patched += 1
print(f"  try/catch stripped in {patched} files")

# ovx.cpp single-line catch bodies confound the stripper — hand patch.
p = Path("modules/core/src/ovx.cpp")
src = p.read_text()
src = src.replace("        try\n", "")
src = src.replace("        catch(const ivx::WrapperError&)\n        { g_haveOpenVX = 0; }\n", "")
src = src.replace("        catch(const ivx::RuntimeError&)\n        { g_haveOpenVX = 0; }\n", "")
p.write_text(src)
print("  ovx.cpp hand-patched")
PYEOF

# --- 3. toolchain + shared-module forcing + setjmp shim ----------------------
cat > "$BUILD/toolchain-wasm.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(CMAKE_C_COMPILER $WASI_SDK/bin/clang)
set(CMAKE_CXX_COMPILER $WASI_SDK/bin/clang++)
set(CMAKE_SYSROOT $WASI_SDK/share/wasi-sysroot)
set(CMAKE_C_COMPILER_TARGET wasm32-wasip2)
set(CMAKE_CXX_COMPILER_TARGET wasm32-wasip2)
set(CMAKE_C_FLAGS "--sysroot=$WASI_SDK/share/wasi-sysroot -fPIC -I$BUILD/sjlj-shim -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_SIGNAL" CACHE STRING "")
set(CMAKE_CXX_FLAGS "--sysroot=$WASI_SDK/share/wasi-sysroot -fPIC -fexceptions -I$BUILD/sjlj-shim -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_SIGNAL" CACHE STRING "")
set(CMAKE_SHARED_LINKER_FLAGS "-fuse-ld=lld -Wl,--unresolved-symbols=import-dynamic -lwasi-emulated-process-clocks -lwasi-emulated-getpid -lwasi-emulated-signal" CACHE STRING "")
set(CMAKE_FIND_ROOT_PATH $WASI_SDK/share/wasi-sysroot)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_CXX_STANDARD_LIBRARIES "-lc++ -lwasi-emulated-process-clocks -lwasi-emulated-getpid -lwasi-emulated-signal $BUILD/cxx_eh_stub.o" CACHE STRING "" FORCE)
EOF
cat > "$BUILD/force-shared.cmake" <<'EOF'
# CMAKE_PROJECT_INCLUDE: force real shared creation (the compiler probes leave
# the create-shared rules empty, which makes SHARED/MODULE fall back to `ar`).
set(_cv_shared_rule "<CMAKE_CXX_COMPILER> <CMAKE_CXX_FLAGS> <LINK_FLAGS> <CMAKE_CXX_SHARED_LIBRARY_CREATE_CXX_FLAGS> -o <TARGET> <OBJECTS> <LINK_LIBRARIES>")
set(_cv_shared_rule_c "<CMAKE_C_COMPILER> <CMAKE_C_FLAGS> <LINK_FLAGS> <CMAKE_C_SHARED_LIBRARY_CREATE_C_FLAGS> -o <TARGET> <OBJECTS> <LINK_LIBRARIES>")
foreach(_v CMAKE_CXX_CREATE_SHARED_LIBRARY CMAKE_CXX_CREATE_SHARED_MODULE)
  set(${_v} "${_cv_shared_rule}")
  set(${_v} "${_cv_shared_rule}" CACHE INTERNAL "" FORCE)
endforeach()
foreach(_v CMAKE_C_CREATE_SHARED_LIBRARY CMAKE_C_CREATE_SHARED_MODULE)
  set(${_v} "${_cv_shared_rule_c}")
  set(${_v} "${_cv_shared_rule_c}" CACHE INTERNAL "" FORCE)
endforeach()
EOF
mkdir -p "$BUILD/sjlj-shim"
cat > "$BUILD/sjlj-shim/setjmp.h" <<'EOF'
/* setjmp/longjmp shim: shadows wasi-sdk's setjmp.h (which #errors without
 * -mllvm -wasm-enable-sjlj, a lowering that emits wasm EH instructions the
 * runtime rejects). setjmp() always returns 0; longjmp() traps. */
#ifndef _OPENCV_SETJMP_SHIM_H
#define _OPENCV_SETJMP_SHIM_H
typedef char jmp_buf[64];
#ifdef __cplusplus
extern "C" {
#endif
int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);
#ifdef __cplusplus
}
#endif
#endif
EOF
cat > "$BUILD/setjmp_stub.c" <<'EOF'
#include "setjmp.h"
int setjmp(jmp_buf env) { (void)env; return 0; }
void longjmp(jmp_buf env, int val) { (void)env; (void)val; __builtin_trap(); }
EOF
# EH + sjlj ABI stubs (compile from the pandas pipeline + this dir)
"$WASI_SDK/bin/clang" --target=wasm32-wasip2 --sysroot="$WASI_SDK/share/wasi-sysroot" -fPIC \
    -c "$HERE/../pandas-pipeline/cxx_eh_stub.c" -o "$BUILD/cxx_eh_stub.o"
"$WASI_SDK/bin/clang" --target=wasm32-wasip2 --sysroot="$WASI_SDK/share/wasi-sysroot" -fPIC \
    -I "$BUILD/sjlj-shim" -c "$BUILD/setjmp_stub.c" -o "$BUILD/setjmp_stub.o"

# --- 4. configure + build ----------------------------------------------------
echo ">>> [extras/08] cmake configure (OpenCV $CV_VERSION, ~1 min)..."
cmake -S "$SRC" -B "$BUILD/build" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/toolchain-wasm.cmake" \
  -DCMAKE_PROJECT_INCLUDE="$BUILD/force-shared.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$BUILD/install" \
  -DBUILD_LIST="core,imgproc,imgcodecs,objdetect,features2d,calib3d,flann,python3,python_bindings_generator" \
  -DBUILD_opencv_python3=ON -DBUILD_opencv_python_bindings_generator=ON \
  -DBUILD_opencv_js=OFF -DBUILD_opencv_java=OFF -DBUILD_opencv_apps=OFF \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
  -DCPU_BASELINE=none -DCPU_DISPATCH=none -DCV_ENABLE_INTRINSICS=OFF -DCV_TRACE=OFF \
  -DWITH_OPENCL=OFF -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_GTK=OFF -DWITH_1394=OFF \
  -DWITH_VTK=OFF -DWITH_EIGEN=OFF -DWITH_TBB=OFF -DWITH_ITT=OFF -DWITH_IPP=OFF -DWITH_PROTOBUF=OFF \
  -DWITH_TIFF=OFF -DBUILD_TIFF=OFF \
  -DBUILD_ZLIB=ON -DBUILD_JPEG=ON -DBUILD_PNG=ON -DBUILD_WEBP=ON -DBUILD_OPENJPEG=ON \
  -DPYTHON3_EXECUTABLE="$CROSS_PY" \
  -DPYTHON3_INCLUDE_PATH="$CROSS_PREFIX/include/python3.14" -DPYTHON3_INCLUDE_DIR="$CROSS_PREFIX/include/python3.14" \
  -DPYTHON3_INCLUDE_DIR2="$CROSS_PREFIX/include/python3.14" \
  -DPYTHON3_LIBRARY="$CROSS_PREFIX/lib/libpython3.14.so" -DPYTHON3_LIBRARIES="$CROSS_PREFIX/lib/libpython3.14.so" \
  -DPYTHON3_NUMPY_INCLUDE_DIRS="$NB/numpy/_core/include" \
  -DPYTHON3_PACKAGES_PATH="$BUILD/opencv-py" \
  2>&1 | tail -2
echo ">>> [extras/08] cmake build (~4 min)..."
cmake --build "$BUILD/build" -j"$(nproc)" 2>&1 | tail -2

# --- 5. link the cv2 module manually (cmake builds it as a static archive) ----
echo ">>> [extras/08] Linking cv2.cpython-314-wasm32-wasi.so..."
cd "$BUILD/build"
"$WASI_SDK/bin/clang++" --target=wasm32-wasip2 --sysroot="$WASI_SDK/share/wasi-sysroot" \
  -fPIC -fexceptions -shared -fuse-ld=lld \
  -Wl,--unresolved-symbols=import-dynamic -Wl,--experimental-pic -Wl,--allow-undefined \
  -o cv2.cpython-314-wasm32-wasi.so \
  modules/python3/CMakeFiles/opencv_python3.dir/__/src2/*.obj \
  lib/libopencv_calib3d.a lib/libopencv_features2d.a lib/libopencv_flann.a \
  lib/libopencv_imgcodecs.a lib/libopencv_imgproc.a lib/libopencv_core.a lib/libopencv_objdetect.a \
  3rdparty/lib/libzlib.a 3rdparty/lib/liblibjpeg-turbo.a 3rdparty/lib/liblibpng.a \
  3rdparty/lib/liblibwebp.a 3rdparty/lib/liblibopenjp2.a \
  -L"$CROSS_PREFIX/lib" -lpython3.14 \
  -lc++ -lwasi-emulated-process-clocks -lwasi-emulated-getpid -lwasi-emulated-signal \
  "$BUILD/cxx_eh_stub.o" "$BUILD/setjmp_stub.o" \
  -L"$WASI_SDK/share/wasi-sysroot/lib/wasm32-wasip2"
"$WASI_SDK/bin/llvm-objdump" -h cv2.cpython-314-wasm32-wasi.so | grep -q dylink \
    || { echo "ERROR: cv2 .so has no dylink section"; exit 1; }

# --- 6. assemble the cv2 package + patch the bootstrap ------------------------
echo ">>> [extras/08] Assembling cv2 package..."
rm -rf "$SITE/cv2"
mkdir -p "$SITE/cv2"
cp -r "$BUILD/build/modules/python_bindings_generator/cv2/." "$SITE/cv2/" 2>/dev/null || true
cp -r "$BUILD/build/python_loader/cv2/." "$SITE/cv2/" 2>/dev/null || true
cp "$BUILD/build/cv2.cpython-314-wasm32-wasi.so" "$SITE/cv2/"
python3 - <<EOF
from pathlib import Path
p = Path("$SITE/cv2/__init__.py")
src = p.read_text()
old = '''    py_module = sys.modules.pop("cv2")

    native_module = importlib.import_module("cv2")

    sys.modules["cv2"] = py_module
    setattr(py_module, "_native", native_module)'''
new = '''    py_module = sys.modules.pop("cv2")

    # WASM patch: the host loader re-imports "cv2" (resolved via the abi3
    # suffix trick); the wasm finder resolves back to this package and
    # recurses. Load the in-package extension directly by path instead.
    import importlib.util as _util
    _spec = _util.spec_from_file_location(
        "cv2", os.path.join(LOADER_DIR, "cv2.cpython-314-wasm32-wasi.so"))
    native_module = _util.module_from_spec(_spec)
    _spec.loader.exec_module(native_module)

    sys.modules["cv2"] = py_module
    setattr(py_module, "_native", native_module)'''
assert old in src, "cv2/__init__.py bootstrap changed upstream"
p.write_text(src.replace(old, new))
print("  cv2 bootstrap patched for wasm")
EOF
echo ">>> [extras/08] done: $(ls "$SITE/cv2/cv2.cpython-314-wasm32-wasi.so")"
