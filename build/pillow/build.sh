#!/bin/bash
# Cross-compile Pillow 9.5.0 (+ zlib + libjpeg-turbo) for wasm32-wasip2 (wasi-sdk-27).
# Reuses the numpy pipeline's wasm CPython. Run in an empty work dir. Required env:
#   CROSS_PREFIX (wasm CPython install prefix), WASI_SDK_PATH (wasi-sdk root), HOST_PYTHON (native 3.14).
# Traps P1-P10: design_docs/code_interpreter_wasm_pillow_build.md. Adapted from bkmashiro/wasi-wheels.
set -eou pipefail

: "${CROSS_PREFIX:?wasm CPython install prefix}"
: "${WASI_SDK_PATH:?wasi-sdk root}"
: "${HOST_PYTHON:?native python3.14}"

WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
DEPS_PREFIX="$(pwd)/wasi-deps"
PILLOW_VERSION="9.5.0"
PILLOW_SRC="Pillow-${PILLOW_VERSION}"
TARGET=wasm32-wasip2

if [ ! -x venv/bin/python ]; then
  "$HOST_PYTHON" -m venv --without-pip venv
  curl -fsSL https://bootstrap.pypa.io/get-pip.py -o venv/get-pip.py
  venv/bin/python venv/get-pip.py
  venv/bin/pip install -q wheel setuptools cmake   # Trap P1: cmake for libjpeg-turbo
fi
. venv/bin/activate

WASI_CFLAGS="--target=$TARGET --sysroot=${WASI_SYSROOT} -fPIC -O3 -msimd128"

# ── zlib ─────────────────────────────────────────────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libz.a" ]; then
  ZLIB_VERSION="1.3.1"
  [ -f "zlib-${ZLIB_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" -o "zlib-${ZLIB_VERSION}.tar.gz"
  tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
  ( cd "zlib-${ZLIB_VERSION}" && CC="${WASI_SDK_PATH}/bin/clang" CFLAGS="${WASI_CFLAGS}" ./configure --prefix="${DEPS_PREFIX}" --static && make -j"$(nproc)" && make install )
fi

# ── libjpeg-turbo (cmake; SIMD off — Trap P2) ────────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libjpeg.a" ]; then
  JPEG_VERSION="2.1.5.1"
  [ -f "libjpeg-turbo-${JPEG_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_VERSION}/libjpeg-turbo-${JPEG_VERSION}.tar.gz" -o "libjpeg-turbo-${JPEG_VERSION}.tar.gz"
  tar xzf "libjpeg-turbo-${JPEG_VERSION}.tar.gz"
  mkdir -p "libjpeg-turbo-${JPEG_VERSION}/build-wasi"
  ( cd "libjpeg-turbo-${JPEG_VERSION}/build-wasi" && cmake .. \
      -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" -DCMAKE_C_FLAGS="${WASI_CFLAGS}" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DWITH_SIMD=FALSE -DWITH_JPEG8=1 -DWITH_TURBOJPEG=FALSE \
      -DENABLE_SHARED=FALSE -DENABLE_STATIC=TRUE -DCMAKE_BUILD_TYPE=Release \
    && make -j"$(nproc)" && make install )
fi

# ── libwebp 1.4.0 (cmake; WebP read/write + webpmux). Pillow 9.5 has NO
#    WEBP_ROOT env var (added 10.4.0) — webp is found via the CFLAGS/LDFLAGS
#    -I/-L dirs below, which already point at ${DEPS_PREFIX}. The mux/demux
#    static libs stay ON (Pillow's webpmux feature probes webp/mux.h +
#    libwebpmux); only the CLI tools are disabled. ────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libwebp.a" ]; then
  WEBP_VERSION="1.4.0"
  [ -f "libwebp-${WEBP_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/webmproject/libwebp/archive/refs/tags/v${WEBP_VERSION}.tar.gz" -o "libwebp-${WEBP_VERSION}.tar.gz"
  tar xzf "libwebp-${WEBP_VERSION}.tar.gz"
  mkdir -p "libwebp-${WEBP_VERSION}/build-wasi"
  ( cd "libwebp-${WEBP_VERSION}/build-wasi" && cmake .. \
      -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" -DCMAKE_C_FLAGS="${WASI_CFLAGS} -fvisibility=hidden -DWEBP_EXTERN=extern" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DWEBP_USE_THREAD=OFF \
      -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
      -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
      -DWEBP_BUILD_WEBPMUX=OFF \
      -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF \
    && make -j"$(nproc)" && make install )
fi

# ── libtiff 4.6.0 (cmake; compressed TIFF — LZW/JPEG/Deflate-in-TIFF — which
#    Pillow's built-in codec cannot read). zlib + jpeg come from this script's
#    own wasi-deps (both already built above). ────────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libtiff.a" ]; then
  TIFF_VERSION="4.6.0"
  [ -f "tiff-${TIFF_VERSION}.tar.gz" ] || curl -fsSL "https://download.osgeo.org/libtiff/tiff-${TIFF_VERSION}.tar.gz" -o "tiff-${TIFF_VERSION}.tar.gz"
  tar xzf "tiff-${TIFF_VERSION}.tar.gz"
  # Trap P4 (same as Pillow's Jpeg.h): wasi-libc's setjmp.h #errors without the
  # EH proposal. libjpeg error recovery uses setjmp/longjmp; stub like Pillow
  # (setjmp returns 0, longjmp traps — a JPEG error aborts the wasm instead of
  # unwinding, identical to the Pillow behavior).
  python3 - <<'PYEOF'
from pathlib import Path
stub = ("#ifdef __wasi__\ntypedef unsigned char jmp_buf[16];\n"
        "#ifndef setjmp\n#define setjmp(env) 0\n#endif\n"
        "#ifndef longjmp\n#define longjmp(env, val) __builtin_trap()\n#endif\n"
        "#else\n#include <setjmp.h>\n#endif\n")
for name in ("tiff-4.6.0/libtiff/tif_jpeg.c", "tiff-4.6.0/libtiff/tif_ojpeg.c"):
    p = Path(name)
    s = p.read_text()
    if "#include <setjmp.h>" in s and "#define setjmp(env) 0" not in s:
        p.write_text(s.replace("#include <setjmp.h>", stub, 1))
        print("patched", name)
PYEOF
  mkdir -p "tiff-${TIFF_VERSION}/build-wasi"
  ( cd "tiff-${TIFF_VERSION}/build-wasi" && cmake .. \
      -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" -DCMAKE_C_FLAGS="${WASI_CFLAGS}" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DZLIB_LIBRARY="${DEPS_PREFIX}/lib/libz.a" -DZLIB_INCLUDE_DIR="${DEPS_PREFIX}/include" \
      -DJPEG_LIBRARY="${DEPS_PREFIX}/lib/libjpeg.a" -DJPEG_INCLUDE_DIR="${DEPS_PREFIX}/include" \
      -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
      -Dtiff-lzma=OFF -Dtiff-zstd=OFF -Dtiff-webp=OFF -Dtiff-jbig=OFF -Dtiff-lerc=OFF \
    && make -j"$(nproc)" && make install )
fi

# ── openjpeg 2.5.2 (cmake; JPEG 2000). Pillow 9.5 probes include dirs for a
#    directory LITERALLY named "openjpeg-<version>" containing openjpeg.h —
#    openjpeg's default install layout (include/openjpeg-2.5) matches, so
#    OPENJPEG_INSTALL_INCLUDE_DIR must NOT be overridden. ────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libopenjp2.a" ]; then
  OPENJPEG_VERSION="2.5.2"
  [ -f "openjpeg-${OPENJPEG_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/uclouvain/openjpeg/archive/refs/tags/v${OPENJPEG_VERSION}.tar.gz" -o "openjpeg-${OPENJPEG_VERSION}.tar.gz"
  tar xzf "openjpeg-${OPENJPEG_VERSION}.tar.gz"
  # opj_clock() uses getrusage/times — WASI has no process-associated clocks
  # (sys/resource.h and sys/times.h #error at include time). Replace with
  # clock_gettime(CLOCK_MONOTONIC), which wasi-libc provides natively.
  python3 - <<'PYEOF'
from pathlib import Path
p = Path("openjpeg-2.5.2/src/lib/openjp2/opj_clock.c")
s = p.read_text()
s = s.replace("#include <sys/time.h>\n#include <sys/resource.h>\n#include <sys/times.h>",
              "#include <sys/time.h>\n#include <time.h>")
s = s.replace("""    /* Unix or Linux: use resource usage */
    struct rusage t;
    OPJ_FLOAT64 procTime;
    /* (1) Get the rusage data structure at this moment (man getrusage) */
    getrusage(0, &t);
    /* (2) What is the elapsed time ? - CPU time = User time + System time */
    /* (2a) Get the seconds */
    procTime = (OPJ_FLOAT64)(t.ru_utime.tv_sec + t.ru_stime.tv_sec);
    /* (2b) More precisely! Get the microseconds part ! */
    return (procTime + (OPJ_FLOAT64)(t.ru_utime.tv_usec + t.ru_stime.tv_usec) *
            1e-6) ;""",
              """    /* WASI: no getrusage — use CLOCK_MONOTONIC (wall-independent). */
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (OPJ_FLOAT64)ts.tv_sec + (OPJ_FLOAT64)ts.tv_nsec * 1e-9;""")
p.write_text(s)
print("patched opj_clock.c")
PYEOF
  mkdir -p "openjpeg-${OPENJPEG_VERSION}/build-wasi"
  ( cd "openjpeg-${OPENJPEG_VERSION}/build-wasi" && cmake .. \
      -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" -DCMAKE_C_FLAGS="${WASI_CFLAGS}" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_DOC=OFF \
    && make -j"$(nproc)" && make install )
fi

# ── libimagequant 2.17.0 (make; PNG quantization for Pillow) ─────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libimagequant.a" ]; then
  IMAGEQUANT_VERSION="2.17.0"
  [ -f "libimagequant-${IMAGEQUANT_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/ImageOptim/libimagequant/archive/refs/tags/${IMAGEQUANT_VERSION}.tar.gz" -o "libimagequant-${IMAGEQUANT_VERSION}.tar.gz"
  tar xzf "libimagequant-${IMAGEQUANT_VERSION}.tar.gz"
  ( cd "libimagequant-${IMAGEQUANT_VERSION}" && \
      make -j"$(nproc)" static CC="${WASI_SDK_PATH}/bin/clang" CFLAGS="${WASI_CFLAGS}" && \
      cp libimagequant.a "${DEPS_PREFIX}/lib/" && \
      cp libimagequant.h "${DEPS_PREFIX}/include/" )
fi

# ── libde265 1.0.15 (autotools; HEVC decoder for HEIC). strukturag's own
#    build-emscripten.sh uses the same autotools flags (--disable-sse
#    --disable-dec265 --disable-sherlock265); pthread probe fails on wasip2 and
#    libde265 falls back to single-threaded decoding. ─────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libde265.a" ]; then
  DE265_VERSION="1.0.15"
  [ -f "libde265-${DE265_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/strukturag/libde265/releases/download/v${DE265_VERSION}/libde265-${DE265_VERSION}.tar.gz" -o "libde265-${DE265_VERSION}.tar.gz"
  tar xzf "libde265-${DE265_VERSION}.tar.gz"
  # config.sub knows wasm32 machines but not the "wasi" OS — map it to -none
  # so autoconf enters cross-compile mode instead of rejecting the triplet.
  python3 - <<'PYEOF'
from pathlib import Path
p = Path("libde265-1.0.15/config.sub")
s = p.read_text()
marker = "case $os in\n"
patch = marker + "\t# wasi (added for wasm32-wasip2 cross builds)\n\t-wasi* | wasi*)\n\t\tos=-none\n\t\t;;\n"
if "wasi" not in s:
    s = s.replace(marker, patch, 1)
    p.write_text(s)
    print("patched config.sub")
# slice.cc includes <signal.h> (line 1632) but uses no signal/raise calls —
# wasi-libc's signal.h #errors without _WASI_EMULATED_SIGNAL. Drop the include.
# Several libde265 sources include <signal.h> (motion.cc, arm/arm.cc, …) but
# never call signal/raise — wasi-libc's signal.h #errors without
# _WASI_EMULATED_SIGNAL. Drop the include everywhere.
import glob
for f in glob.glob("libde265-1.0.15/**/*.cc", recursive=True):
    t = Path(f).read_text()
    if "#include <signal.h>" in t:
        Path(f).write_text(t.replace("#include <signal.h>\n", "", 1))
        print("patched", f)
# wasi-libc has no real pthreads (its stubs trap in the wasm runtime), so
# force single-threaded decoding: de265_start_worker_threads() becomes a no-op.
# The decoder fully supports num_worker_threads=0 (serial postprocessing),
# which is the default when the pool is never started. libheif calls this
# unconditionally, so the call must succeed without starting anything.
d = Path("libde265-1.0.15/libde265/de265.cc")
t = d.read_text()
old = """  if (number_of_threads > MAX_THREADS) {
    number_of_threads = MAX_THREADS;
  }

  if (number_of_threads>0) {
    de265_error err = ctx->start_thread_pool(number_of_threads);
    if (de265_isOK(err)) {
      err = DE265_OK;
    }
    return err;
  }
  else {
    return DE265_OK;
  }
}"""
new = """  (void)de265ctx;
  (void)number_of_threads;
  /* wasm32-wasip2: wasi-libc pthreads are trap stubs, so decoding must run
   * single-threaded (num_worker_threads=0 — the serial postprocessing path). */
  return DE265_OK;
}"""
if old in t:
    d.write_text(t.replace(old, new, 1))
    print("patched de265_start_worker_threads (single-threaded)")
else:
    print("WARN: de265_start_worker_threads body not found — check libde265 version")
PYEOF
  ( cd "libde265-${DE265_VERSION}" && \
      CC="${WASI_SDK_PATH}/bin/clang" CXX="${WASI_SDK_PATH}/bin/clang++" \
      CFLAGS="${WASI_CFLAGS}" CXXFLAGS="${WASI_CFLAGS}" \
      LDFLAGS="--target=$TARGET --sysroot=${WASI_SYSROOT}" \
      ./configure --host=wasm32-wasi --prefix="${DEPS_PREFIX}" \
        --enable-static --disable-shared \
        --disable-sse --disable-dec265 --disable-sherlock265 --disable-encoder \
  )
  # Trim SUBDIRS to the library only: tools/ (block-rate-estim) fails to
  # cross-link on wasm (C++ exceptions) and is not shipped.
  python3 - <<'PYEOF'
from pathlib import Path
p = Path("libde265-1.0.15/Makefile")
s = p.read_text()
lines = s.splitlines(keepends=True)
out, i = [], 0
while i < len(lines):
    line = lines[i]
    if line.startswith("SUBDIRS ="):
        out.append("SUBDIRS = libde265\n")
        i += 1
        while i < len(lines) and lines[i].strip().startswith(("libde265", "tools", "acceleration-speed", "$(am__append_")):
            i += 1  # drop continuation lines
        continue
    out.append(line)
    i += 1
p.write_text("".join(out))
print("trimmed SUBDIRS")
PYEOF
  ( cd "libde265-${DE265_VERSION}" && make -j"$(nproc)" && make install )
fi

# ── libheif 1.17.3 (cmake; decode-only HEIC via libde265 — no encoders, no
#    plugins, no threading). Version pinned to match pillow-heif 1.3.0's
#    requirement (libheif >= 1.17.0; newer pillow-heif wants 1.19+/1.23+). ────
if [ ! -f "${DEPS_PREFIX}/lib/libheif.a" ]; then
  HEIF_VERSION="1.17.3"
  [ -f "libheif-${HEIF_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/strukturag/libheif/releases/download/v${HEIF_VERSION}/libheif-${HEIF_VERSION}.tar.gz" -o "libheif-${HEIF_VERSION}.tar.gz"
  tar xzf "libheif-${HEIF_VERSION}.tar.gz"
  # emscripten-only include in the decode path (pyodide applies the same sed)
  sed -i 's@#include "heif_emscripten.h"@@' "libheif-${HEIF_VERSION}/libheif/heif.cc"
  mkdir -p "libheif-${HEIF_VERSION}/build-wasi"
  ( cd "libheif-${HEIF_VERSION}/build-wasi" && cmake .. \
      -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" -DCMAKE_CXX_COMPILER="${WASI_SDK_PATH}/bin/clang++" \
      -DCMAKE_C_FLAGS="${WASI_CFLAGS}" -DCMAKE_CXX_FLAGS="${WASI_CFLAGS}" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
      -DENABLE_PLUGIN_LOADING=OFF -DENABLE_MULTITHREADING_SUPPORT=OFF -DENABLE_PARALLEL_TILE_DECODING=OFF \
      -DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF \
      -DWITH_LIBDE265=ON -DLIBDE265_INCLUDE_DIR="${DEPS_PREFIX}/include" -DLIBDE265_LIBRARY="${DEPS_PREFIX}/lib/libde265.a" \
      -DWITH_X265=OFF -DWITH_KVAZAAR=OFF -DWITH_DAV1D=OFF \
      -DWITH_AOM_ENCODER=OFF -DWITH_AOM_DECODER=OFF -DWITH_SvtEnc=OFF -DWITH_RAV1E=OFF \
      -DWITH_FFMPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF -DWITH_OpenJPEG_DECODER=OFF \
      -DWITH_JPEG_ENCODER=OFF -DWITH_JPEG_DECODER=OFF -DWITH_LIBSHARPYUV=OFF \
    && make -j"$(nproc)" && make install )
fi

# ── Pillow source ────────────────────────────────────────────────────────────
if [ ! -d "${PILLOW_SRC}" ]; then
  [ -f "${PILLOW_SRC}.tar.gz" ] || curl -fsSL "https://files.pythonhosted.org/packages/00/d5/4903f310765e0ff2b8e91ffe55031ac6af77d982f0156061e20a4d1a8b2d/Pillow-9.5.0.tar.gz" -o "${PILLOW_SRC}.tar.gz"
  tar xzf "${PILLOW_SRC}.tar.gz"
  # PEP 667 (py3.13+): locals() is a snapshot, so Pillow 9.5.0's get_version —
  # exec(_version.py) then `locals()["__version__"]` — KeyErrors under the
  # 3.14 host python (cold-build regression caught 2026-08-06). Redirect to
  # globals().
  python3 - << 'PYEOF'
from pathlib import Path
p = Path("Pillow-9.5.0/setup.py")
s = p.read_text()
s = s.replace('exec(compile(f.read(), version_file, "exec"))',
              'exec(compile(f.read(), version_file, "exec"), globals())')
s = s.replace('return locals()["__version__"]', 'return globals()["__version__"]')
p.write_text(s)
print("patched Pillow setup.py get_version for PEP 667")
PYEOF
  # Trap P11 (wasm ABI): METH_NOARGS handlers MUST take exactly
  # (PyObject *self, PyObject *unused). wasm32 call_indirect type-checks the
  # arity, so Pillow's historical 0-arg/1-arg handlers compile to ()->i32 /
  # (i32)->i32 and TRAP with "indirect call type mismatch" whenever CPython
  # dispatches them (method_vectorcall_NOARGS/cfunction_vectorcall_NOARGS).
  # Native x86-64 tolerates the extra register arg, so this is wasm-only.
  # Affected: _webp.c (5), _imaging.c (7), _imagingft.c (2), encode.c (1).
  # See vllm-responses design_docs/code_interpreter_wasm_webp_got_trap.md §9.
  python3 - << 'PYEOF'
from pathlib import Path

fixes = {
    "Pillow-9.5.0/src/_webp.c": {
        "WebPDecoderVersion_wrapper() {": "WebPDecoderVersion_wrapper(PyObject *self, PyObject *unused) {",
        "WebPDecoderBuggyAlpha_wrapper() {": "WebPDecoderBuggyAlpha_wrapper(PyObject *self, PyObject *unused) {",
        "_anim_decoder_get_info(PyObject *self) {": "_anim_decoder_get_info(PyObject *self, PyObject *unused) {",
        "_anim_decoder_get_next(PyObject *self) {": "_anim_decoder_get_next(PyObject *self, PyObject *unused) {",
        "_anim_decoder_reset(PyObject *self) {": "_anim_decoder_reset(PyObject *self, PyObject *unused) {",
    },
    "Pillow-9.5.0/src/_imaging.c": {
        "_isblock(ImagingObject *self) {": "_isblock(ImagingObject *self, PyObject *unused) {",
        "_getbbox(ImagingObject *self) {": "_getbbox(ImagingObject *self, PyObject *unused) {",
        "_getextrema(ImagingObject *self) {": "_getextrema(ImagingObject *self, PyObject *unused) {",
        "_getprojection(ImagingObject *self) {": "_getprojection(ImagingObject *self, PyObject *unused) {",
        "_split(ImagingObject *self) {": "_split(ImagingObject *self, PyObject *unused) {",
        "_getpalettemode(ImagingObject *self) {": "_getpalettemode(ImagingObject *self, PyObject *unused) {",
        "_chop_invert(ImagingObject *self) {": "_chop_invert(ImagingObject *self, PyObject *unused) {",
    },
    "Pillow-9.5.0/src/_imagingft.c": {
        "font_getvarnames(FontObject *self) {": "font_getvarnames(FontObject *self, PyObject *unused) {",
        "font_getvaraxes(FontObject *self) {": "font_getvaraxes(FontObject *self, PyObject *unused) {",
    },
    "Pillow-9.5.0/src/encode.c": {
        "_encode_to_pyfd(ImagingEncoderObject *encoder) {": "_encode_to_pyfd(ImagingEncoderObject *encoder, PyObject *unused) {",
    },
}
total = 0
for rel, repls in fixes.items():
    p = Path(rel)
    s = p.read_text()
    for old, new in repls.items():
        n = s.count(old)
        assert n == 1, f"{rel}: expected 1 occurrence of {old!r}, found {n}"
        s = s.replace(old, new)
        total += 1
    p.write_text(s)
print(f"patched {total} METH_NOARGS handlers to 2-arg form (Trap P11)")
PYEOF
fi

# ── clang wrapper: strip host -I/usr/... includes (Trap P9) ──────────────────
WRAPPER_DIR="$(pwd)/wrapper"
mkdir -p "$WRAPPER_DIR"
REAL_CLANG="${WASI_SDK_PATH}/bin/clang"; REAL_CLANGXX="${WASI_SDK_PATH}/bin/clang++"
cat > "${WRAPPER_DIR}/clang" <<'WRAPPER'
#!/bin/bash
args=()
for arg in "$@"; do
  case "$arg" in
    -I/usr/include|-I/usr/include/*|-I/usr/local/include|-I/usr/local/include/*) ;;
    *) args+=("$arg") ;;
  esac
done
exec "@REAL_CLANG@" "${args[@]}"
WRAPPER
sed -i "s|@REAL_CLANG@|${REAL_CLANG}|g" "${WRAPPER_DIR}/clang"
cp "${WRAPPER_DIR}/clang" "${WRAPPER_DIR}/clang++"
sed -i "s|${REAL_CLANG}|${REAL_CLANGXX}|g" "${WRAPPER_DIR}/clang++"
chmod +x "${WRAPPER_DIR}/clang" "${WRAPPER_DIR}/clang++"

# ── __wasi_proc_exit stub (Trap P3) ──────────────────────────────────────────
cat > "${WRAPPER_DIR}/wasi_compat.c" <<'CEOF'
__attribute__((noreturn))
void __wasi_proc_exit(int code) { __builtin_trap(); }
CEOF
"${WASI_SDK_PATH}/bin/clang" --target=$TARGET --sysroot="${WASI_SYSROOT}" -fPIC -c "${WRAPPER_DIR}/wasi_compat.c" -o "${WRAPPER_DIR}/wasi_compat.o"
"${WASI_SDK_PATH}/bin/llvm-ar" rcs "${WRAPPER_DIR}/libwasi_compat.a" "${WRAPPER_DIR}/wasi_compat.o"

# ── build Pillow ─────────────────────────────────────────────────────────────
cd "${PILLOW_SRC}"
# Jpeg.h setjmp stub (Trap P4)
python3 - <<'PYEOF'
import sys
path = "src/libImaging/Jpeg.h"; src = open(path).read()
stub = ("#ifdef __wasi__\ntypedef unsigned char jmp_buf[16];\n"
        "#ifndef setjmp\n#define setjmp(env) 0\n#endif\n"
        "#ifndef longjmp\n#define longjmp(env, val) __builtin_trap()\n#endif\n"
        "#else\n#include <setjmp.h>\n#endif\n")
patched = src.replace("#include <setjmp.h>", stub, 1)
if patched != src:
    open(path, "w").write(patched); print("patched Jpeg.h setjmp")
PYEOF

# ── freetype (reuse matplotlib's build) + fake setjmp.h ──────────────────────
# Pillow 9.5's feature probes read self.compiler.{include,library}_dirs, which
# only see the CFLAGS/LDFLAGS -I/-L dirs (the *_ROOT env vars go into a local
# list the probes never look at) — so freetype-install's dirs MUST ride in
# CFLAGS/LDFLAGS. And freetype headers pull <setjmp.h> (ftstdlib.h) — wasi-libc
# #errors without the EH proposal — so the matplotlib pipeline's fake setjmp.h
# must shadow the sysroot header via -isystem BEFORE the sysroot dirs.
MPL_FREETYPE="${WASI_BUILD:-/tmp/wasi-build}/matplotlib-build/freetype-install"
MPL_FAKEHDRS="${WASI_BUILD:-/tmp/wasi-build}/matplotlib-build/fake-headers"
FAKEHDR_FLAG=""
if [ -f "$MPL_FAKEHDRS/setjmp.h" ]; then
  FAKEHDR_FLAG="-isystem ${MPL_FAKEHDRS}"
  echo "  fake setjmp.h: $MPL_FAKEHDRS"
fi
FREETYPE_FLAGS=""
if [ -d "$MPL_FREETYPE" ]; then
  export FREETYPE_ROOT="$MPL_FREETYPE"
  FREETYPE_FLAGS="-I${MPL_FREETYPE}/include -L${MPL_FREETYPE}/lib"
  echo "  freetype root: $MPL_FREETYPE"
fi

export CC="${WRAPPER_DIR}/clang" CXX="${WRAPPER_DIR}/clang++"
export AR="${WASI_SDK_PATH}/bin/llvm-ar" RANLIB="${WASI_SDK_PATH}/bin/llvm-ranlib" STRIP="${WASI_SDK_PATH}/bin/llvm-strip"
export CFLAGS="${FAKEHDR_FLAG} --target=$TARGET --sysroot=${WASI_SYSROOT} -isystem ${WASI_SYSROOT}/include -isystem ${WASI_SYSROOT}/include/$TARGET -I${CROSS_PREFIX}/include/python3.14 -I${DEPS_PREFIX}/include ${FREETYPE_FLAGS} -D__EMSCRIPTEN__=1 -fPIC"
export LDFLAGS="--target=$TARGET --sysroot=${WASI_SYSROOT} -L${DEPS_PREFIX}/lib -L${WASI_SYSROOT}/lib/$TARGET -L${CROSS_PREFIX}/lib -L${WRAPPER_DIR} ${FREETYPE_FLAGS} -Wl,--whole-archive -lsharpyuv -Wl,--no-whole-archive ${CROSS_PREFIX}/lib/libpython3.14.so -shared -Wl,--experimental-pic -Wl,--unresolved-symbols=import-dynamic -lwasi_compat"
export LDSHARED="${WRAPPER_DIR}/clang"
export ZLIB_ROOT="${DEPS_PREFIX}" JPEG_ROOT="${DEPS_PREFIX}" DISABLE_PLATFORM_GUESSING=1
# T1 image-format roots (Pillow 9.5 probe table: TIFF_ROOT / JPEG2K_ROOT /
# IMAGEQUANT_ROOT / FREETYPE_ROOT; webp has no root var in 9.5 — found via the
# CFLAGS/LDFLAGS -I/-L above, which already include ${DEPS_PREFIX}).
export TIFF_ROOT="${DEPS_PREFIX}" JPEG2K_ROOT="${DEPS_PREFIX}" IMAGEQUANT_ROOT="${DEPS_PREFIX}"
export PYTHONPATH="${CROSS_PREFIX}/lib/python3.14"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi

# Trap P7: build_ext emits only .so; bdist_wheel + unpack gives the full PIL (.py + .so).
python3 setup.py build_ext --plat-name $TARGET
python3 setup.py bdist_wheel --plat-name $TARGET
wheel unpack --dest build dist/[Pp]illow-*.whl
echo "PILLOW_DONE: $(ls build/*/PIL/__init__.py)"

# ── _wasi_heif extension (HEIC/HEIF decode; see _wasi_heif.c for why this
#    exists instead of pillow-heif: libffi's wasm32 port is emscripten-only,
#    so cffi's _cffi_backend cannot be built for wasip2) ──────────────────────
HEIF_PY="${WASI_BUILD:-/tmp/wasi-build}/heif-py"
HEIF_EXT="_wasi_heif.cpython-314-wasm32-wasi.so"
if [ ! -f "../heif-py/${HEIF_EXT}" ]; then
  REPO_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp "$REPO_HERE/_wasi_heif.c" "$REPO_HERE/wasi_heif.py" .
  # wasi-sdk's libc++abi is built WITHOUT exceptions (no EH proposal), so
  # __cxa_throw/__cxa_allocate_exception are undefined in every static lib.
  # HEIC decode never throws (libheif returns error codes); stub them to trap,
  # same philosophy as the __wasi_proc_exit / setjmp stubs above.
  cat > heif_compat.c <<'HEIFEOF'
__attribute__((noreturn))
void __cxa_throw(void *a, void *b, void *c) { __builtin_trap(); }
__attribute__((noreturn))
void *__cxa_allocate_exception(unsigned long size) { __builtin_trap(); }
HEIFEOF
  "${WASI_SDK_PATH}/bin/clang" ${WASI_CFLAGS} -c heif_compat.c -o heif_compat.o
  "${WRAPPER_DIR}/clang++" ${WASI_CFLAGS} \
      -I"${DEPS_PREFIX}/include" -I"${CROSS_PREFIX}/include/python3.14" \
      -L"${DEPS_PREFIX}/lib" -L"${WASI_SYSROOT}/lib/$TARGET" -L"${CROSS_PREFIX}/lib" -L"${WRAPPER_DIR}" \
      ${CROSS_PREFIX}/lib/libpython3.14.so -shared -nostdlib++ -Wl,--experimental-pic \
      -Wl,--unresolved-symbols=import-dynamic -lwasi_compat \
      _wasi_heif.c -lheif -lde265 -l:libc++.a -l:libc++abi.a heif_compat.o \
      -o "$HEIF_EXT"
  mkdir -p "$HEIF_PY"
  cp "$HEIF_EXT" "$HEIF_PY/"
  cp wasi_heif.py "$HEIF_PY/"
  echo "HEIF_EXT_DONE: $(ls "$HEIF_PY")"
fi

echo "HEIF_PY staged: $(ls "$HEIF_PY" 2>/dev/null || echo 'absent (fresh tree builds it above)')"
