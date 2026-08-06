#!/bin/bash
# numpy meson.build patches for the wasm cross-build:
#   (Wall 3) find_installation(pure: false) defaults to the python running meson (host);
#            point it at the cross-python wrapper so it introspects the wasm sysconfig.
#   (Wall 9) numpy's C++ extensions (_multiarray_umath, _pocketfft_umath) need the C++ EH
#            stub linked in (wasi-sdk-27 libc++abi has no exceptions). Add cxx_eh_stub.c to
#            their sources.
#
# Usage: patch-numpy-meson.sh <numpy-source-dir> <cross-python.sh> <cxx_eh_stub.c>
set -euo pipefail
SRC="${1:?usage: patch-numpy-meson.sh <numpy-source-dir> <cross-python.sh> <cxx_eh_stub.c>}"
CROSS_PY="${2:?missing cross-python.sh path}"
EH_STUB="${3:?missing cxx_eh_stub.c path}"

# Stage the EH stub into the source tree (meson compiles it as a normal source file).
cp "$EH_STUB" "$SRC/numpy/_core/cxx_eh_stub.c"
cp "$EH_STUB" "$SRC/numpy/fft/cxx_eh_stub.c"

python3 - "$SRC" "$CROSS_PY" <<'PYEOF'
import sys
from pathlib import Path
src, cross_py = Path(sys.argv[1]), sys.argv[2]

# (Wall 3) point find_installation at the cross-python wrapper.
mb = src / "meson.build"; t = mb.read_text()
old = "py = import('python').find_installation(pure: false)"
new = f"py = import('python').find_installation('{cross_py}', pure: false)"
if cross_py in t:
    print("meson.build find_installation already patched")
elif old in t:
    mb.write_text(t.replace(old, new, 1)); print("patched meson.build find_installation")
else:
    sys.exit("ERROR: find_installation pattern not found in meson.build")

# (Wall 9) add cxx_eh_stub.c to _multiarray_umath common sources.
mc = src / "numpy/_core/meson.build"; t = mc.read_text()
anchor = "src_multiarray_umath_common = [\n"
if "cxx_eh_stub.c" in t:
    print("_core/meson.build EH stub already added")
elif anchor in t:
    mc.write_text(t.replace(anchor, anchor + "  'cxx_eh_stub.c',\n", 1))
    print("added cxx_eh_stub.c to src_multiarray_umath_common")
else:
    sys.exit("ERROR: src_multiarray_umath_common anchor not found")

# (Wall 9) add cxx_eh_stub.c to _pocketfft_umath sources.
mf = src / "numpy/fft/meson.build"; t = mf.read_text()
anchor2 = "  ['_pocketfft_umath.cpp'],"
if "cxx_eh_stub.c" in t:
    print("fft/meson.build EH stub already added")
elif anchor2 in t:
    mf.write_text(t.replace(anchor2, "  ['_pocketfft_umath.cpp', 'cxx_eh_stub.c'],", 1))
    print("added cxx_eh_stub.c to _pocketfft_umath")
else:
    sys.exit("ERROR: _pocketfft_umath sources anchor not found")
PYEOF
