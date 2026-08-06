#!/usr/bin/env python3
"""Bypass-meson WASI build of pandas _libs: cythonize natively, cross-compile with wasi-sdk-27.

Mirrors pandas' meson.build extension list (read from pandas/_libs/*/meson.build). Compiles
against the numpy 2.5.1 wasm install (stage 2) so the pandas .so match the runtime numpy exactly
(same C-API table). The one C++ extension (window/aggregations) is cythonized with --cplus and
linked with clang++ + the C++ EH stub (wasi-sdk-27 libc++abi has no exceptions).

Env (set by 03-pandas.sh):
  WASI_BUILD    build root (default /tmp/wasi-build)
  NUMPY_SITE    numpy 2.5.1 install site-packages dir (has numpy/ with .pxd + _core/include)
  PD_SRC        pandas source dir (default $WASI_BUILD/pandas/pandas-src)
  PD_OUT        output package dir (default $WASI_BUILD/pandas/pandas-wasi)
  HERE          this pipeline dir (for cxx_eh_stub.c)

Usage: build_pandas_libs.py [ext_name ...]   (no args = build all)
"""
import os
import subprocess
import sys

WASI_BUILD = os.environ.get("WASI_BUILD", "/tmp/wasi-build")
NUMPY_SITE = os.environ["NUMPY_SITE"]
SRC = os.environ.get("PD_SRC", f"{WASI_BUILD}/pandas/pandas-src")
OUT = os.environ.get("PD_OUT", f"{WASI_BUILD}/pandas/pandas-wasi")
HERE = os.environ.get("HERE", os.path.dirname(os.path.abspath(__file__)))
SDK = f"{WASI_BUILD}/wasi-sdk"
CROSS_PREFIX = f"{WASI_BUILD}/cpython-wasi/install"
PY_INC = f"{CROSS_PREFIX}/include/python3.14"
NUMPY_INC = f"{NUMPY_SITE}/numpy/_core/include"   # wasm32-configured, matches runtime
NUMPY_PXD = NUMPY_SITE                            # cython finds numpy/*.pxd here
PD_INC = f"{SRC}/pandas/_libs/include"
PXi = f"{WASI_BUILD}/pandas/pxi-out"
CYTHON = os.environ.get("CYTHON", "cython")
EH_STUB = f"{HERE}/cxx_eh_stub.c"
EH_OBJ = f"{WASI_BUILD}/pandas/cxx_eh_stub.o"

CC = f"{SDK}/bin/clang"
CXX = f"{SDK}/bin/clang++"
COMMON_DEFS = [
    "-D__EMSCRIPTEN__=1", "-DNPY_NO_SIGNAL", "-DNPY_NO_DEPRECATED_API=0",
    "-DNPY_TARGET_VERSION=NPY_1_21_API_VERSION", "-DCYTHON_USE_TYPE_SPECS=1",
]
INCLUDES = [f"-I{PY_INC}", f"-I{NUMPY_INC}", f"-I{PD_INC}"]
LDFLAGS = [
    "-shared", "-fuse-ld=lld", "-Wl,--unresolved-symbols=import-dynamic",
    f"{CROSS_PREFIX}/lib/libpython3.14.so", "-lm",
]

# name -> dict(subdir, pyx, c_sources, cpp). subdir "" == pandas/_libs.
EXT = {
    "algos":        dict(subdir="", pyx=["algos.pyx"], c=[], cpp=False),
    "arrays":       dict(subdir="", pyx=["arrays.pyx"], c=[], cpp=False),
    "groupby":      dict(subdir="", pyx=["groupby.pyx"], c=[], cpp=False),
    "hashing":      dict(subdir="", pyx=["hashing.pyx"], c=[], cpp=False),
    "hashtable":    dict(subdir="", pyx=["hashtable.pyx"], c=[], cpp=False),
    "index":        dict(subdir="", pyx=["index.pyx"], c=[], cpp=False),
    "indexing":     dict(subdir="", pyx=["indexing.pyx"], c=[], cpp=False),
    "internals":    dict(subdir="", pyx=["internals.pyx"], c=[], cpp=False),
    "interval":     dict(subdir="", pyx=["interval.pyx"], c=[], cpp=False),
    "join":         dict(subdir="", pyx=["join.pyx"], c=[], cpp=False),
    "lib":          dict(subdir="", pyx=["lib.pyx"], c=["src/parser/tokenizer.c"], cpp=False),
    "missing":      dict(subdir="", pyx=["missing.pyx"], c=[], cpp=False),
    "pandas_datetime": dict(subdir="", pyx=[], c=[
        "src/vendored/numpy/datetime/np_datetime.c",
        "src/vendored/numpy/datetime/np_datetime_strings.c",
        "src/datetime/date_conversions.c", "src/datetime/pd_datetime.c"], cpp=False),
    "pandas_parser": dict(subdir="", pyx=[], c=[
        "src/parser/tokenizer.c", "src/parser/io.c", "src/parser/pd_parser.c"], cpp=False),
    "parsers":      dict(subdir="", pyx=["parsers.pyx"], c=["src/parser/tokenizer.c", "src/parser/io.c"], cpp=False),
    "json":         dict(subdir="", pyx=[], c=[
        "src/vendored/ujson/python/ujson.c", "src/vendored/ujson/python/objToJSON.c",
        "src/vendored/ujson/python/JSONtoObj.c", "src/vendored/ujson/lib/ultrajsonenc.c",
        "src/vendored/ujson/lib/ultrajsondec.c"], cpp=False),
    "ops":          dict(subdir="", pyx=["ops.pyx"], c=[], cpp=False),
    "ops_dispatch": dict(subdir="", pyx=["ops_dispatch.pyx"], c=[], cpp=False),
    "properties":   dict(subdir="", pyx=["properties.pyx"], c=[], cpp=False),
    "reshape":      dict(subdir="", pyx=["reshape.pyx"], c=[], cpp=False),
    "sas":          dict(subdir="", pyx=["sas.pyx"], c=[], cpp=False),
    "byteswap":     dict(subdir="", pyx=["byteswap.pyx"], c=[], cpp=False),
    "sparse":       dict(subdir="", pyx=["sparse.pyx"], c=[], cpp=False),
    "tslib":        dict(subdir="", pyx=["tslib.pyx"], c=[], cpp=False),
    "testing":      dict(subdir="", pyx=["testing.pyx"], c=[], cpp=False),
    "writers":      dict(subdir="", pyx=["writers.pyx"], c=[], cpp=False),
    # ---- tslibs ----
    "base":         dict(subdir="tslibs", pyx=["base.pyx"], c=[], cpp=False),
    "ccalendar":    dict(subdir="tslibs", pyx=["ccalendar.pyx"], c=[], cpp=False),
    "dtypes":       dict(subdir="tslibs", pyx=["dtypes.pyx"], c=[], cpp=False),
    "conversion":   dict(subdir="tslibs", pyx=["conversion.pyx"], c=[], cpp=False),
    "fields":       dict(subdir="tslibs", pyx=["fields.pyx"], c=[], cpp=False),
    "nattype":      dict(subdir="tslibs", pyx=["nattype.pyx"], c=[], cpp=False),
    "np_datetime":  dict(subdir="tslibs", pyx=["np_datetime.pyx"], c=[], cpp=False),
    "offsets":      dict(subdir="tslibs", pyx=["offsets.pyx"], c=[], cpp=False),
    "parsing":      dict(subdir="tslibs", pyx=["parsing.pyx"], c=["../src/parser/tokenizer.c"], cpp=False),
    "period":       dict(subdir="tslibs", pyx=["period.pyx"], c=[], cpp=False),
    "strptime":     dict(subdir="tslibs", pyx=["strptime.pyx"], c=[], cpp=False),
    "timedeltas":   dict(subdir="tslibs", pyx=["timedeltas.pyx"], c=[], cpp=False),
    "timestamps":   dict(subdir="tslibs", pyx=["timestamps.pyx"], c=[], cpp=False),
    "timezones":    dict(subdir="tslibs", pyx=["timezones.pyx"], c=[], cpp=False),
    "tzconversion": dict(subdir="tslibs", pyx=["tzconversion.pyx"], c=[], cpp=False),
    "vectorized":   dict(subdir="tslibs", pyx=["vectorized.pyx"], c=[], cpp=False),
    # ---- window ----
    "aggregations": dict(subdir="window", pyx=["aggregations.pyx"], c=[], cpp=True),
    "indexers":     dict(subdir="window", pyx=["indexers.pyx"], c=[], cpp=False),
}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def ensure_eh_obj():
    if not os.path.exists(EH_OBJ):
        r = run([CC, "--target=wasm32-wasip2", f"--sysroot={SDK}/share/wasi-sysroot",
                 "-fPIC", "-O2", "-c", EH_STUB, "-o", EH_OBJ])
        if r.returncode != 0:
            raise RuntimeError(f"failed to compile EH stub: {r.stderr}")


def build_ext(name, spec):
    subdir, pyx_list, c_sources, is_cpp = spec["subdir"], spec["pyx"], spec["c"], spec["cpp"]
    ext_dir = os.path.join(SRC, "pandas/_libs", subdir) if subdir else os.path.join(SRC, "pandas/_libs")
    work = f"{WASI_BUILD}/pandas/obj/{name}"
    os.makedirs(work, exist_ok=True)
    objs = []

    # 1. cythonize .pyx -> .c/.cpp
    for pyx in pyx_list:
        pyx_path = os.path.join(ext_dir, pyx)
        ext = ".cpp" if is_cpp else ".c"
        out_c = os.path.join(work, pyx.replace(".pyx", ext))
        cy = [CYTHON, "-3", "-X", "always_allow_keywords=true", "--include-dir", PXi,
              "-I", NUMPY_PXD, "-I", SRC]
        if is_cpp:
            cy.append("--cplus")
        cy += [pyx_path, "-o", out_c]
        r = run(cy)
        if r.returncode != 0:
            return f"CYTHON_FAIL {pyx}: {r.stderr[-1500:]}"
        objs.append(out_c)

    # 2. C sources (absolute)
    for csrc in c_sources:
        objs.append(os.path.normpath(os.path.join(ext_dir, csrc)))

    # 3. cross-compile -> .so
    out_dir = os.path.join(OUT, "pandas/_libs", subdir) if subdir else os.path.join(OUT, "pandas/_libs")
    os.makedirs(out_dir, exist_ok=True)
    so = os.path.join(out_dir, f"{name}.cpython-314-wasm32-wasi.so")
    if is_cpp:
        ensure_eh_obj()
        cmd = ([CXX, "--target=wasm32-wasip2", f"--sysroot={SDK}/share/wasi-sysroot",
                "-fPIC", "-O2", "-std=c++17"] + COMMON_DEFS + INCLUDES + objs +
               [EH_OBJ, "-lc++"] + LDFLAGS + ["-o", so])
    else:
        cmd = ([CC, "--target=wasm32-wasip2", f"--sysroot={SDK}/share/wasi-sysroot",
                "-fPIC", "-O2"] + COMMON_DEFS + INCLUDES + objs + LDFLAGS + ["-o", so])
    r = run(cmd)
    if r.returncode != 0:
        return f"CC_FAIL: {r.stderr[-1800:]}"
    return None


def main():
    only = sys.argv[1:]
    os.makedirs(OUT, exist_ok=True)
    ok, fail = [], []
    for name, spec in EXT.items():
        if only and name not in only:
            continue
        err = build_ext(name, spec)
        if err:
            fail.append((name, err)); print(f"[FAIL] {name}")
        else:
            ok.append(name); print(f"[ OK ] {name}")
    print(f"\n==== {len(ok)} ok, {len(fail)} failed ====")
    for name, err in fail:
        print(f"\n----- {name} -----\n{err}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
