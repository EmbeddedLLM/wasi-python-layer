#!/bin/bash
# Wall 7 fix: numpy's temp_elide.c uses dladdr/Dl_info/backtrace (glibc dynamic-link
# introspection), guarded by `#if defined HAVE_BACKTRACE && defined HAVE_DLFCN_H`. meson
# detects both for wasm (the sysroot ships a dlfcn.h stub) but WASI has no dladdr.
# Add `&& !defined(__wasi__)` so the #else fallback (no backtrace) is used.
#
# Usage: patch-numpy-temp-elide.sh <numpy-source-dir>
set -euo pipefail
SRC="${1:?usage: patch-numpy-temp-elide.sh <numpy-source-dir>}"
F="$SRC/numpy/_core/src/multiarray/temp_elide.c"
[ -f "$F" ] || { echo "ERROR: $F not found"; exit 1; }
OLD='#if defined HAVE_BACKTRACE && defined HAVE_DLFCN_H'
NEW='#if defined HAVE_BACKTRACE && defined HAVE_DLFCN_H && !defined(__wasi__)'
if grep -qF "$NEW" "$F"; then
  echo "already patched: $F"
elif grep -qF "$OLD" "$F"; then
  # Only patch the first (outer) occurrence that opens the dladdr block.
  python3 - "$F" "$OLD" "$NEW" <<'PYEOF'
import sys
f, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(f).read()
open(f, "w").write(t.replace(old, new, 1))
print("patched", f)
PYEOF
else
  echo "ERROR: pattern not found in $F"; exit 1
fi
