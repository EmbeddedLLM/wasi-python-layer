#!/bin/bash
# Wall 2 fix: patch the HOST CPython's pyconfig.h to wasm32 (ILP32) sizes.
#
# meson derives the python *include dir* from sys.executable's location (the host python),
# not from the cross-python wrapper's sysconfig. So the cython sanity check compiles against
# the host pyconfig.h (x86_64: SIZEOF_VOID_P=8, LONG_BIT=64) with the wasm32 compiler
# (sizeof(void*)=4) -> "LONG_BIT wrong" / "SIZEOF_VOID_P == sizeof(void*) division by zero".
# Patching the host pyconfig.h to wasm32 sizes fixes every compile-only probe. It is a
# compile-time header; the host python binary is already built, so this is safe.
#
# Usage: patch-pyconfig-wasm32.sh <host-python-install-prefix>
#   e.g. patch-pyconfig-wasm32.sh $WASI_BUILD/cpython-host/install
set -euo pipefail
PREFIX="${1:?usage: patch-pyconfig-wasm32.sh <host-python-install-prefix>}"
PYCFG="$PREFIX/include/python3.14/pyconfig.h"
[ -f "$PYCFG" ] || { echo "ERROR: $PYCFG not found"; exit 1; }
cp -n "$PYCFG" "$PYCFG.x86bak" 2>/dev/null || true   # one-time backup
# x86_64 (LP64) -> wasm32 (ILP32): long/void*/size_t/uintptr/pthread_t go 8 -> 4.
# long long / off_t / time_t / double stay 8.
sed -i -E \
  -e 's/^#define SIZEOF_LONG 8$/#define SIZEOF_LONG 4/' \
  -e 's/^#define SIZEOF_VOID_P 8$/#define SIZEOF_VOID_P 4/' \
  -e 's/^#define SIZEOF_SIZE_T 8$/#define SIZEOF_SIZE_T 4/' \
  -e 's/^#define SIZEOF_UINTPTR_T 8$/#define SIZEOF_UINTPTR_T 4/' \
  -e 's/^#define SIZEOF_PTHREAD_T 8$/#define SIZEOF_PTHREAD_T 4/' \
  "$PYCFG"
echo "patched $PYCFG to wasm32 sizes:"
grep -E '^#define SIZEOF_(LONG|VOID_P|SIZE_T|UINTPTR_T|PTHREAD_T|LONG_LONG) ' "$PYCFG"
