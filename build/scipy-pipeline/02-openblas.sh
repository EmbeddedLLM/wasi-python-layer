#!/bin/bash
# Stage 3 / M3: build single-threaded static OpenBLAS 0.3.31 for wasm32-wasip2.
#
# Reference: pyodide's libopenblas recipe (packages/libopenblas) — the
# generic-C-kernel trick is TARGET=RISCV64_GENERIC + a Makefile hack that
# neuters the -march/-mabi flags (the RISCV64_GENERIC core is plain portable
# C). BINARY=32, NOFORTRAN=1, NO_LAPACKE=1, USE_THREAD=0, no SIMD initially
# (plan §3 initial rules). Static libopenblas.a, separate from libf2c.a
# (plan Stage 3: keep archives separate for symbol debugging).
#
# Lessons applied:
#  - host-side probes (c_check/f_check/gensymbol) MUST run with HOSTCC=gcc —
#    they are config codegen, same split as cross-python.sh / arithchk (the
#    wasm build cannot execute its own probes).
#  - void→int return-type seds (BLASFUNC/cblas_/interface/lapack-netlib):
#    same wasm ABI strictness as f2c patch 0004 — kept verbatim from pyodide.
#  - sha256-pin the tarball; patch application uses dry-run-then-apply.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
export WASI_SDK_PATH="${WASI_SDK_PATH:-$WASI_BUILD/wasi-sdk}"
BUILD="$WASI_BUILD/scipy-build"
DEPS="$BUILD/deps"
SRC="$BUILD/OpenBLAS-0.3.31"
TARBALL="$BUILD/openblas-0.3.31.tar.gz"
OPENBLAS_SHA256="6dd2a63ac9d32643b7cc636eab57bf4e57d0ed1fff926dfbc5d3d97f2d2be3a6"
URL="https://github.com/OpenMathLib/OpenBLAS/releases/download/v0.3.31/OpenBLAS-0.3.31.tar.gz"

mkdir -p "$DEPS/lib" "$DEPS/include"

if [ -f "$DEPS/lib/libopenblas.a" ]; then
  echo "[openblas] already built: $DEPS/lib/libopenblas.a"
  exit 0
fi

# ── download (sha256-pinned) ───────────────────────────────────────────────
if [ ! -f "$TARBALL" ]; then
  echo "[openblas] downloading 0.3.31 ..."
  curl -fsSL --max-time 300 "$URL" -o "$TARBALL"
fi
echo "$OPENBLAS_SHA256  $TARBALL" | sha256sum -c -

# ── extract ────────────────────────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
  tar xzf "$TARBALL" -C "$BUILD"
fi
# c_check/f_check are GENERATED scripts that ship ONLY in the release
# tarball (not in git); nothing in the tree can regenerate them. The prebuild
# (Makefile.system's DUMMY) silently fails without them, leaving no config.h.
if [ ! -x "$SRC/c_check" ] || [ ! -x "$SRC/f_check" ]; then
  echo "[openblas] restoring c_check/f_check from tarball"
  tar xzf "$TARBALL" -C "$SRC" --strip-components=1 \
      OpenBLAS-0.3.31/c_check OpenBLAS-0.3.31/f_check
  chmod +x "$SRC/c_check" "$SRC/f_check"
fi
cd "$SRC"

# ── patches (pyodide, WASI-verified) ───────────────────────────────────────
for p in "$HERE"/patches/openblas/*.patch; do
  echo "[openblas] applying $(basename "$p")"
  if patch -p1 --forward --dry-run -s < "$p" 2>/dev/null; then
    patch -p1 --forward -s < "$p"
  else
    echo "  (already applied or not applicable — $(basename "$p"))"
  fi
done

# ── pyodide's target hacks + void→int seds (kept verbatim, see recipe) ─────
sed -i 's@ifeq ($(CORE), RISCV64_GENERIC)@ifeq ($(CORE), NOT_RISCV64_GENERIC)@g' Makefile.riscv64
sed -i 's@ifeq ($(TARGET), RISCV64_GENERIC)@ifeq ($(TARGET), NOT_RISCV64_GENERIC)@g' Makefile.prebuild
sed -ri 's/void(\s+)BLASFUNC/int\1BLASFUNC/g' common_interface.h
sed -ri 's/void(\s+)cblas_/int\1cblas_/g' cblas.h ctest/*.c
sed -ri 's/void(\s+)(C?NAME)/int\1\2/g' interface/*.c
sed -ri 's/((extern)?.+) void ([a-z0-9]+_)/\1\2 int \3/g' lapack-netlib/SRC/*.c \
    lapack-netlib/SRC/DEPRECATED/*.c
sed -ri 's/^void (LAED4|LACPY|LASET)\(/int \1(/g' lapack/laed3/*.c
sed -ri 's@int ([cz](dotc|dotu|ladiv))@void \1@g' lapack-netlib/SRC/*.c \
    lapack-netlib/SRC/DEPRECATED/*.c

# BINARY=32 makes OpenBLAS add -m32/-m64 host-arch flags — meaningless and
# rejected by wasi clang (wasm32 is inherently 32-bit; pointers are 32-bit).
# Neutralize all five sites (2x CCOMMON_OPT, 3x FCOMMON_OPT).
sed -i 's/^\([[:space:]]*CCOMMON_OPT += \)-m32$/\1# wasm32 is inherently 32-bit/' Makefile.system
sed -i 's/^\([[:space:]]*FCOMMON_OPT += \)-m32$/\1# wasm32 is inherently 32-bit/' Makefile.system

# SMP: with USE_THREAD=0 OpenBLAS sets `SMP =` (empty), but `ifdef SMP` still
# fires on the empty-defined var, adding -DSMP_SERVER; common.h:68 aliases
# SMP_SERVER -> SMP, which re-enables the parallel dispatch (dgetrf_parallel
# etc.) and its threading imports. Make the flag conditional on an actual `1`.
sed -i 's@^ifdef SMP$@ifeq ($(SMP), 1)@' Makefile.system
sed -i 's@^ifdef SMP$@ifeq ($(SMP), 1)@' Makefile.tail
sed -i 's@^ifdef SMP$@ifeq ($(SMP), 1)@' driver/others/Makefile
sed -i 's@^ifdef SMP$@ifeq ($(SMP), 1)@' interface/Makefile
sed -i 's@^ifdef SMP$@ifeq ($(SMP), 1)@' lapack/getrf/Makefile lapack/getrs/Makefile

# ctest.c is the c_check probe source (preprocess-only — no execution needed).
# It has no __wasi__ case, so config.h would lack an OS marker entirely
# (empty OSNAME/ARCH). Emit OS_WASI + reuse riscv64 as the arch marker.
sed -i '/#if defined(__linux__)/i #if defined(__wasi__)\nOS_WASI\n#endif\n' ctest.c
# Arch marker: reuse ARCH_RISCV64 (c_check.pl already matches it) so config.h
# pulls in common_riscv64.h, whose MB/WMB/RMB are __sync_synchronize() —
# portable, wasm-safe. The make-level ARCH=riscv64 + TARGET=RISCV64_GENERIC select the
# kernel/generic C kernels.
sed -i '/#if defined(__riscv)/i #if defined(__wasm__)\nARCH_RISCV64\n#endif\n' ctest.c

# common.h: WASI lacks sys/shm.h — treat it like Android/Haiku.
sed -i '/#if defined(OS_HAIKU) || defined(OS_QNX)/i #if defined(OS_WASI)\n#define NO_SYSV_IPC\n#endif\n' common.h

# memory.c includes <sys/ipc.h> unconditionally under the !OS_EMBEDDED guard
# (wasi has no SysV IPC). Fold it under the same NO_SYSV_IPC guard as shm.h.
perl -0pi -e 's@#ifndef NO_SYSV_IPC\n#include <sys/shm.h>\n#endif\n#include <sys/ipc.h>@#ifndef NO_SYSV_IPC\n#include <sys/shm.h>\n#include <sys/ipc.h>\n#endif@' driver/others/memory.c

# BUFFER_SIZE: OpenBLAS allocates a per-module buffer pool on the FIRST pooled
# BLAS call (dtrsv_ etc. via blas_memory_alloc); on the riscv64-generic
# stand-in arch it is 32MB. Inside the sandbox's 128MB memory cap the
# allocation fails after the earlier gates and OpenBLAS exits(1) — observed
# on gate 13.7 (spsolve -> SuperLU -> dtrsv_), 2026-08-10. Shrink to 8MB
# (GEMM panel depth derives from BUFFER_SIZE; 8MB is far above the ~1.6MB
# floor). MUST be applied before `make clean` so the rebuilt memory.o carries
# the new size.
if grep -q "#define BUFFER_SIZE     ( 32 << 20)" common_riscv64.h; then
  sed -i 's/#define BUFFER_SIZE     ( 32 << 20)/#define BUFFER_SIZE     ( 8 << 20)/' common_riscv64.h
  echo "[openblas] BUFFER_SIZE 32MB -> 8MB (sandbox memory cap)"
else
  echo "[openblas] BUFFER_SIZE already shrunk"
fi

# ── build static lib (generic C kernels, single-threaded) ──────────────────
# Full clean: make does not track CFLAGS changes, so stale objects from
# earlier (SMP) attempts would keep the parallel imports.
make clean >/dev/null 2>&1 || true
export CC="${WASI_SDK_PATH}/bin/clang --target=wasm32-wasip2 --sysroot=${WASI_SDK_PATH}/share/wasi-sysroot -fPIC -O2"
export HOSTCC="${HOSTCC:-gcc}"
export AR="${WASI_SDK_PATH}/bin/llvm-ar"
export RANLIB="${WASI_SDK_PATH}/bin/llvm-ranlib"
export NOFORTRAN=1 NO_LAPACKE=1 USE_THREAD=0 DYNAMIC_ARCH=0 BINARY=32
echo "[openblas] make libs (ARCH=riscv64, TARGET=RISCV64_GENERIC, single-threaded)..."
# OSNAME/ARCH are normally detected by compile-and-run probes (c_check/getarch)
# that CANNOT run wasm on the host. Command-line vars override the empty
# file values; ARCH=riscv64 + TARGET=RISCV64_GENERIC select the portable C
# kernels (kernel/generic) with no arch-specific flags.
# HOSTCC=gcc: Makefile.rule leaves HOSTCC commented out; the getarch probe
# must be a HOST binary (it runs on this machine), not a wasm module.
# CFLAGS: wasi's sys/mman.h hard-errors unless _WASI_EMULATED_MMAN is set
# (malloc-backed mmap emulation; link with -lwasi-emulated-mman at consumer);
# NO_SYSV_IPC skips common.h's <sys/shm.h> (wasi has no SysV shm). Note:
# c_check.pl has no OS_WASI matcher, so config.h's OS marker stays empty —
# the command-line OSNAME/ARCH overrides handle the makefile-level logic.
make libs -j"$(nproc)" OSNAME=Linux ARCH=riscv64 TARGET=RISCV64_GENERIC HOSTCC=gcc CFLAGS="-D_WASI_EMULATED_MMAN -DNO_SYSV_IPC"
# netlib (the f2c-converted LAPACK): the `libs` target builds only the FLAME
# subset (12 dirs: getrf/getrs/...); the rest of LAPACK lives in
# lapack-netlib and builds only via the `netlib` target (part of `shared`,
# which we skip). scipy's _flapack imports ~hundreds of these (ztpqrt etc.).
make netlib OSNAME=Linux ARCH=riscv64 TARGET=RISCV64_GENERIC HOSTCC=gcc CFLAGS="-D_WASI_EMULATED_MMAN -DNO_SYSV_IPC" -j"$(nproc)"
make install OSNAME=Linux ARCH=riscv64 TARGET=RISCV64_GENERIC HOSTCC=gcc CFLAGS="-D_WASI_EMULATED_MMAN -DNO_SYSV_IPC" NO_SHARED=1 PREFIX="$DEPS"
# merge the netlib archive into libopenblas.a (single -lopenblas for scipy)
# grep -q + pipefail race (SIGPIPE 141): capture the listing first.
OBLAS_ARCHIVE_T="$(mktemp)"
"$WASI_SDK_PATH/bin/llvm-ar" t "$DEPS/lib/libopenblas.a" > "$OBLAS_ARCHIVE_T" 2>/dev/null || true
if [ -f "$SRC/lapack-netlib/SRC/liblapack.a" ] && ! grep -q "^ztpqrt" "$OBLAS_ARCHIVE_T"; then
  echo "[openblas] merging netlib liblapack.a into libopenblas.a"
  "$WASI_SDK_PATH/bin/llvm-ar" q "$DEPS/lib/libopenblas.a" "$SRC/lapack-netlib/SRC/liblapack.a"
  "$WASI_SDK_PATH/bin/llvm-ranlib" "$DEPS/lib/libopenblas.a"
fi
rm -f "$OBLAS_ARCHIVE_T"

# ── Stage 3 validation ─────────────────────────────────────────────────────
echo "[openblas] validating..."
( cd /tmp/openblas-check 2>/dev/null || mkdir -p /tmp/openblas-check && cd /tmp/openblas-check
  "$WASI_SDK_PATH/bin/llvm-ar" x "$DEPS/lib/libopenblas.a" 2>/dev/null || true )
file "$DEPS/lib/libopenblas.a" >/dev/null
OBJ_COUNT=$("$WASI_SDK_PATH/bin/llvm-ar" t "$DEPS/lib/libopenblas.a" | wc -l)
echo "  objects: $OBJ_COUNT"
if [ "$OBJ_COUNT" -lt 100 ]; then echo "  [FAIL] too few objects" >&2; exit 1; fi
UNDEF=$("$WASI_SDK_PATH/bin/llvm-nm" -u "$DEPS/lib/libopenblas.a" 2>/dev/null | sort -u)
case "$UNDEF" in
  *pthread*|*dlopen*|*fork*|*signal*)
    echo "  [FAIL] unwanted imports:" >&2
    echo "$UNDEF" >&2
    exit 1
    ;;
esac
echo "  [ok] no pthread/dlopen/fork/signal imports"
echo "[openblas] DONE: $DEPS/lib/libopenblas.a ($(du -h "$DEPS/lib/libopenblas.a" | cut -f1))"
