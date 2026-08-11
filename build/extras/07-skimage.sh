#!/bin/bash
# extras/07-skimage.sh — scikit-image (meson/Cython cross-build).
#
# scipy 1.18.0 IS available for wasm32-wasip2 as of 2026-08-10 (the scipy
# pipeline: libf2c + OpenBLAS + C_LAPACK f2c ABI, see
# design_docs/code_interpreter_wasm_scipy_build.md) and ships in the same
# layer, so skimage's full scipy-dependent surface is enabled — color
# (colorconv), filters, morphology, measure, segmentation, transform,
# restoration, graph, metrics, feature. Earlier builds shipped a scipy-free
# subset with module-level scipy imports guarded; that guard was removed with
# the scipy enablement (2026-08-10). Verified in the functional sweep.
#
# Build: meson cross (numpy 02-numpy251.sh recipe): wasm32-wasip2 clang,
# cross-python.sh (wasm sysconfig), -Dnumpy-include-dir points at the wasm numpy
# headers. Cython runs on the host, generates C, cross-compiled.
#
# Usage: SITE=/path/site-packages bash 07-skimage.sh   (default $WASI_BUILD/extras-site)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
CROSS_PY="$WASI_BUILD/cross-python.sh"
SK_VERSION="0.26.0"
BUILD="$WASI_BUILD/skimage-build"
NB="$WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages"
export PATH="$WASI_BUILD/build-venv/bin:$PATH"   # meson, cython, ninja, pythran

mkdir -p "$BUILD" "$SITE"

echo ">>> [extras/07] Fetching scikit-image $SK_VERSION sdist..."
SK_URL="$(curl -s "https://pypi.org/pypi/scikit-image/$SK_VERSION/json" \
    | jq -r '.urls[] | select(.filename | endswith(".tar.gz")) | .url' | head -1)"
[ -n "$SK_URL" ] || { echo "ERROR: scikit-image sdist not found"; exit 1; }
if [ ! -d "$BUILD/scikit_image-$SK_VERSION" ]; then
    curl -sL -o "$BUILD/scikit-image-$SK_VERSION.tar.gz" "$SK_URL"
    tar -xf "$BUILD/scikit-image-$SK_VERSION.tar.gz" -C "$BUILD"
fi
SRC="$BUILD/scikit_image-$SK_VERSION"

# Pure-python deps (skimage.io + graph): networkx, imageio, tifffile, lazy_loader
echo ">>> [extras/07] Fetching pure deps (networkx, imageio, tifffile, lazy_loader)..."
DL="$BUILD/deps"
mkdir -p "$DL"
"$WASI_BUILD/build-venv/bin/pip" download -q --no-deps --only-binary :all: \
    -d "$DL" networkx imageio tifffile lazy_loader
for whl in "$DL"/*.whl; do unzip -qo "$whl" -d "$SITE"; done
rm -rf "$SITE"/*.dist-info "$SITE"/*.data

# imageio queries `importlib.metadata.version("imageio")` at import time, so it
# needs its dist-info back (networkx/tifffile/lazy_loader do not query their own
# metadata at import; lazy_loader degrades gracefully without it).
echo ">>> [extras/07] Restoring imageio dist-info..."
unzip -qo "$DL"/imageio-*.whl 'imageio-*.dist-info/*' -d "$SITE"
[ -n "$(ls -d "$SITE"/imageio-*.dist-info 2>/dev/null)" ] || { echo "ERROR: imageio dist-info not restored"; exit 1; }

# Cython must be importable inside cross-python.sh (PYTHONHOME = wasm install) —
# meson's tempita custom_target runs `import Cython.Tempita` through it. Install
# the pure-python Cython into the wasm install's site-packages (host-side).
echo ">>> [extras/07] Ensuring Cython importable in cross-python..."
"$WASI_BUILD/build-venv/bin/pip" install -q --target \
    "$CROSS_PREFIX/lib/python3.14/site-packages" "Cython==3.2.8"

# Cross-file (numpy recipe + python + numpy-include-dir property)
cat > "$BUILD/wasi-cross.ini" <<EOF
[binaries]
c = '$WASI_SDK/bin/clang'
cpp = '$WASI_SDK/bin/clang++'
ar = '$WASI_SDK/bin/llvm-ar'
strip = '$WASI_SDK/bin/llvm-strip'
python = '$CROSS_PY'
cython = '$WASI_BUILD/build-venv/bin/cython'

[built-in options]
c_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK/share/wasi-sysroot', '-fPIC']
c_link_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK/share/wasi-sysroot', '-shared', '-fuse-ld=lld', '-Wl,--unresolved-symbols=import-dynamic']
cpp_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK/share/wasi-sysroot', '-fPIC', '-fexceptions']
cpp_link_args = ['--target=wasm32-wasip2', '--sysroot=$WASI_SDK/share/wasi-sysroot', '-shared', '-fuse-ld=lld', '-Wl,--unresolved-symbols=import-dynamic']

[host_machine]
system = 'wasi'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'

[properties]
sys_root = '$WASI_SDK/share/wasi-sysroot'
needs_exe_wrapper = true
longdouble_format = 'IEEE_QUAD_LE'
numpy-include-dir = '$NB/numpy/_core/include'
pythran-include-dir = '$WASI_BUILD/build-venv/lib/python3.14/site-packages/pythran'
EOF

# C++ modules need the __cxa_* EH ABI stubs (wasm libpython exports none).
# Cross-file edits don't reliably regenerate ninja link lines, so pass
# cpp_link_args explicitly on the setup command line.
"$WASI_SDK/bin/clang" --target=wasm32-wasip2 --sysroot="$WASI_SDK/share/wasi-sysroot" \
    -fPIC -c "$HERE/../pandas-pipeline/cxx_eh_stub.c" -o "$BUILD/cxx_eh_stub.o"
cd "$SRC"
# tempita custom_target runs `import Cython.Tempita` through cross-python.sh,
# whose PYTHONHOME redirect hides the host stdlib (no math etc.) — patch it to
# run with the build-venv (host) python instead. Only morphology uses py3.
sed -i "s|    py3, tempita,|    '$WASI_BUILD/build-venv/bin/python', tempita,|" \
    src/skimage/morphology/meson.build
echo ">>> [extras/07] meson setup (skimage $SK_VERSION)"
if [ -d build/meson-info ]; then RECONF="--reconfigure"; else RECONF=""; fi
meson setup $RECONF build --cross-file="$BUILD/wasi-cross.ini" \
    -Dcpp_link_args="['--target=wasm32-wasip2', '--sysroot=$WASI_SDK/share/wasi-sysroot', '-shared', '-fuse-ld=lld', '-Wl,--unresolved-symbols=import-dynamic', '$BUILD/cxx_eh_stub.o']"
echo ">>> [extras/07] meson compile (this is the long step: 51 Cython modules)"
meson compile -C build 2>&1 | tail -5
echo ">>> [extras/07] meson install"
meson install -C build --destdir "$BUILD/skimage-install"

echo ">>> [extras/07] Assembling skimage into $SITE..."
rm -rf "$SITE/skimage"
INST="$BUILD/skimage-install"
if [ -d "$INST/usr/local" ]; then
    cp -r "$INST/usr/local/lib/python3.14/site-packages/skimage" "$SITE/skimage"
else
    echo "ERROR: no install output; build failed above"; exit 1
fi
# scipy 1.18.0 IS available on wasm as of 2026-08-10 (scipy-pipeline, see
# design_docs/code_interpreter_wasm_scipy_build.md) and ships in the same
# layer, so skimage's scipy-dependent surface is fully enabled: color
# (colorconv -> scipy.linalg/ndimage), filters, morphology, measure,
# segmentation, transform, restoration, graph, metrics, feature. No import
# guards.
# erics VFS gap: C-level reads on mounted/baked site files return ENOSYS, so
# skimage.morphology's import-time np.load of disk/ball_decompositions.npy
# fails in every erics sandbox (python open() works, numpy's native file IO
# does not). Bake the two uint8 repetition tables into footprints.py as
# literals (they are small: (251,3) / (101,3)). Idempotent.
python3 - <<EOF
import numpy as np
from pathlib import Path
d = Path("$SITE/skimage/morphology")
disk = np.load(d / "disk_decompositions.npy", allow_pickle=False).tolist()
ball = np.load(d / "ball_decompositions.npy", allow_pickle=False).tolist()
p = d / "footprints.py"
src = p.read_text()
if "WASI-baked" in src:
    print("  footprints.py already baked")
else:
    old2 = "_nsphere_decompositions[2] = np.load(\n    os.path.join(os.path.dirname(__file__), 'disk_decompositions.npy')\n)"
    old3 = "_nsphere_decompositions[3] = np.load(\n    os.path.join(os.path.dirname(__file__), 'ball_decompositions.npy')\n)"
    assert old2 in src and old3 in src, "footprints.py np.load lines not found"
    new2 = "_nsphere_decompositions[2] = np.array(\n    %r, dtype=np.uint8\n)  # WASI-baked (np.load unavailable in erics)" % (disk,)
    new3 = "_nsphere_decompositions[3] = np.array(\n    %r, dtype=np.uint8\n)  # WASI-baked (np.load unavailable in erics)" % (ball,)
    src = src.replace(old2, new2).replace(old3, new3)
    p.write_text(src)
    print("  footprints.py decompositions baked (disk %dx3, ball %dx3)" % (len(disk), len(ball)))
EOF
echo ">>> [extras/07] Installed:"
ls -d "$SITE/skimage" "$SITE/networkx" "$SITE/imageio" "$SITE/tifffile" "$SITE/lazy_loader"
find "$SITE/skimage" -name "*.so" | wc -l
