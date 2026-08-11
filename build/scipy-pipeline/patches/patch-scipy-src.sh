#!/bin/bash
# Stage 8: apply ALL scipy source patches for the WASI build. Idempotent —
# each patch checks for its marker before applying. Call BEFORE meson setup
# (cython_lapack_signatures.txt feeds the cythonize at compile time; the
# __init__ guards ship in the install).
# Usage: patch-scipy-src.sh <scipy-src>
set -euo pipefail
SRC="${1:?scipy source dir}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── ctypes guards (_ccallback, _ccallback_c.pyx, stats, arff) ─────────────
bash "$HERE/patch-scipy-ctypes.sh" "$SRC"

# ── FIX 1 (gate 13.3): batched-linalg LAPACK ABI. scipy 1.18's new batched
#    C++ path (scipy/linalg/src/_common_array_utils.hh) declares the 124
#    LAPACK entry points `void`; OpenBLAS (f2c ABI) defines them `int` ->
#    wasm-ld signature-mismatch trap thunks on scipy.linalg.solve/inv/det/
#    lstsq (batched path — nothing falls back). ───────────────────────────
F="$SRC/scipy/linalg/src/_common_array_utils.hh"
if ! grep -q "^int BLAS_FUNC" "$F"; then
  sed -i 's/^void BLAS_FUNC/int BLAS_FUNC/g' "$F"
  echo "[scipy-src] _common_array_utils.hh: void BLAS_FUNC -> int BLAS_FUNC (FIX 1)"
else
  echo "[scipy-src] _common_array_utils.hh already patched (FIX 1)"
fi
# C sibling (same class; 44 decls): consumed by _internal_matfuncs
# (_matfuncs_expm.c/_matfuncs_sqrtm.c) — without it scipy.linalg.expm traps
# on signature_mismatch:dgemv_ (gate 15.1). Zero other ^void lines — bulk
# rule is safe.
F="$SRC/scipy/linalg/src/_common_array_utils.h"
if ! grep -q "^int BLAS_FUNC" "$F"; then
  sed -i 's/^void BLAS_FUNC/int BLAS_FUNC/g' "$F"
  echo "[scipy-src] _common_array_utils.h: void BLAS_FUNC -> int BLAS_FUNC (FIX 1 C sibling)"
else
  echo "[scipy-src] _common_array_utils.h already patched (FIX 1 C sibling)"
fi

# ── cython_lapack signatures: f2c ABI is int-returning after the pyodide
#    void->int seds on the OpenBLAS f2c LAPACK (see 02-openblas.sh). The
#    generated cython_lapack.pyx is void-typed -> wasm-ld signature
#    mismatches at the _flapack/cython_lapack links. The cz dotc/dotu/ladiv
#    complex returns are declared with `c`/`z` return types (not `void`), so
#    the bulk rule never touches them. ────────────────────────────────────
F="$SRC/scipy/linalg/cython_lapack_signatures.txt"
if ! grep -q "^int dbbcsd(" "$F"; then
  sed -ri 's/^void ([a-z0-9]+)\(/int \1(/' "$F"
  echo "[scipy-src] cython_lapack_signatures.txt: void->int f2c ABI"
else
  echo "[scipy-src] cython_lapack_signatures.txt already patched"
fi

# ── cython_blas signatures: same class as cython_lapack (f2c ABI is
#    int-returning). The generated cython_blas.pyx is void-typed -> wasm-ld
#    signature mismatches at the cython_blas link (trap thunks + marshaling
#    adapters, gate 15). Value-returning entries (c/d/s/z/bint/int returns:
#    dot/nrm2/dasum/dcabs1/amax/lsame/...) are untouched by the bulk void
#    rule. ───────────────────────────────────────────────────────────────
F="$SRC/scipy/linalg/cython_blas_signatures.txt"
if ! grep -q "^int caxpy(" "$F"; then
  sed -ri 's/^void ([a-z0-9]+)\(/int \1(/' "$F"
  echo "[scipy-src] cython_blas_signatures.txt: void->int f2c ABI"
else
  echo "[scipy-src] cython_blas_signatures.txt already patched"
fi

# ── threads dependency: meson's dependency('threads') injects -pthread on
#    the cross (scipy/meson.build + the HiGHS subproject), which clashes with
#    -mno-atomics (the erics component encoder rejects atomics modules). The
#    dep IS found on the wasm cross, so disabler never fires; replace with an
#    empty declare_dependency(). ─────────────────────────────────────────
F="$SRC/scipy/meson.build"
if ! grep -q "WASI: threads dep" "$F"; then
  python3 - "$F" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "thread_dep = dependency('threads', required: false)\n"
new = """# WASI: threads dep injects -pthread which clashes with -mno-atomics
# (the erics component encoder rejects atomics modules)
thread_dep = declare_dependency()
"""
assert old in s, "scipy/meson.build: expected thread_dep line not found"
open(p, "w").write(s.replace(old, new, 1))
PYEOF
  echo "[scipy-src] scipy threads dep neutralized"
else
  echo "[scipy-src] scipy threads dep already neutralized"
fi
F="$SRC/subprojects/highs/meson.build"
if ! grep -q "WASI: threads dep" "$F"; then
  python3 - "$F" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "threads_dep = dependency('threads', required: false)\n"
new = """# WASI: threads dep injects -pthread which clashes with -mno-atomics
threads_dep = declare_dependency()
"""
assert old in s, "highs/meson.build: expected threads_dep line not found"
open(p, "w").write(s.replace(old, new, 1))
PYEOF
  echo "[scipy-src] highs threads dep neutralized"
else
  echo "[scipy-src] highs threads dep already neutralized"
fi

# ── scipy/fft/__init__.py: duccfft workers import guarded (WASI boundary:
#    pyduccfft needs libc++ string/mutex ABI the no-exceptions wasi
#    libc++abi cannot provide; with the minimal cxx_eh_stub relink
#    (Stage 14 addendum) pyduccfft works — scipy 1.18 has NO pocketfft
#    fallback; fft runs on duccfft). ────────────────────────────────────
F="$SRC/scipy/fft/__init__.py"
if ! grep -q "WASI boundary" "$F"; then
  python3 - "$F" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "from ._duccfft.helper import set_workers, get_workers\n"
new = """# WASI boundary: duccfft's C++ pulls the libc++ string/mutex ABI which the
# no-exceptions wasi libc++abi cannot provide; with the minimal stub relink
# pyduccfft works — scipy 1.18 has no pocketfft fallback, fft runs on duccfft.
try:
    from ._duccfft.helper import set_workers, get_workers
except ImportError:
    def set_workers(workers=None):
        pass
    def get_workers():
        return 1
"""
assert old in s, "fft/__init__.py: expected import line not found"
open(p, "w").write(s.replace(old, new, 1))
EOF
  echo "[scipy-src] fft/__init__.py ducc workers guarded"
else
  echo "[scipy-src] fft/__init__.py already patched"
fi

# ── scipy/stats/__init__.py: qmc import guarded (WASI boundary: _qmc_cy
#    needs libc++ std::thread ABI — same cause). qmc becomes None. ───────
F="$SRC/scipy/stats/__init__.py"
if ! grep -q "WASI boundary" "$F"; then
  python3 - "$F" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "from . import qmc\n"
new = """# WASI boundary: _qmc_cy's C++ needs the libc++ std::thread ABI which the
# no-exceptions wasi libc++abi cannot provide (component encoder rejects it).
try:
    from . import qmc
except ImportError:
    qmc = None
"""
assert old in s, "stats/__init__.py: expected qmc import not found"
open(p, "w").write(s.replace(old, new, 1))
EOF
  echo "[scipy-src] stats/__init__.py qmc guarded"
else
  echo "[scipy-src] stats/__init__.py already patched"
fi

# ── scipy/fft/_basic.py: give every uarray multimethod a default
#    implementation routing to _basic_backend. WASI (2026-08-10): the
#    vendored uarray C dispatch never finds the 'scipy' global backend inside
#    the erics wasm sandbox (set_global_backend's store is not visible to the
#    dispatcher), so the plain multimethod raises BackendNotImplementedError.
#    uarray's Function::call falls back to the multimethod's *default* when
#    zero backends succeed, so the default keeps scipy.fft fully functional
#    (identical numerics — it IS the scipy backend's implementation). ───────
F="$SRC/scipy/fft/_basic.py"
if ! grep -q "WASI: uarray default" "$F"; then
  python3 - "$F" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''def _dispatch(func):
    """
    Function annotation that creates a uarray multimethod from the function
    """
    return generate_multimethod(func, _x_replacer, domain="numpy.scipy.fft")'''
new = '''def _dispatch(func):
    """
    Function annotation that creates a uarray multimethod from the function.
    WASI: uarray default (2026-08-10) — see patch-scipy-src.sh.
    """
    def _default(*args, **kwargs):
        from scipy.fft import _basic_backend
        return getattr(_basic_backend, func.__name__)(*args, **kwargs)

    return generate_multimethod(func, _x_replacer, domain="numpy.scipy.fft",
                                default=_default)'''
assert old in s, "fft/_basic.py: expected _dispatch not found"
open(p, "w").write(s.replace(old, new, 1))
PYEOF
  echo "[scipy-src] fft/_basic.py uarray default impl added"
else
  echo "[scipy-src] fft/_basic.py uarray default already patched"
fi

# ── SuperLU BLAS/LAPACK declarations: f2c ABI is int-returning (same class
#    as FIX 1 / cython_lapack). SuperLU's vendored C port declares them
#    `extern void dtrsv_(...)` etc.; OpenBLAS defines them int -> wasm-ld
#    trap thunks on the spsolve path (signature_mismatch:dtrsv_, gate 13.7).
#    Covers the SRC headers AND the .c files (several redeclare the BLAS
#    names directly; scipy_slu_blas_config.h macro-maps them). ────────────
F="$SRC/scipy/sparse/linalg/_dsolve/SuperLU/SRC/slu_ddefs.h"
if ! grep -q "extern int dtrsv_(" "$F"; then
  for blasf in $(grep -rlE "extern void [a-z0-9]*_\(" \
      "$SRC/scipy/sparse/linalg/_dsolve/SuperLU/SRC/"*.c \
      "$SRC/scipy/sparse/linalg/_dsolve/SuperLU/SRC/"*.h \
      "$SRC/scipy/sparse/linalg/_dsolve/"*.c \
      "$SRC/scipy/sparse/linalg/_dsolve/"*.h 2>/dev/null); do
    sed -i -E 's/extern void ([a-z0-9]+)_\(/extern int \1_(/g' "$blasf"
  done
  echo "[scipy-src] SuperLU BLAS/LAPACK extern void -> extern int"
else
  echo "[scipy-src] SuperLU BLAS/LAPACK already patched"
fi

# ── arpack (arnaud) BLAS/LAPACK declarations: same class as SuperLU. The
#    converted-C ARPACK tree declares the Fortran BLAS/LAPACK entry points
#    `void ARNAUD_BLAS(name)(...)` (ARNAUD_BLAS(name) == BLAS_FUNC(name) ==
#    name##_); OpenBLAS (f2c ABI) defines them int -> wasm-ld trap thunks +
#    marshaling adapters on the eigsh/eigs path (signature_mismatch:*, gate
#    15). Only the ARNAUD_BLAS declarations are touched — arnaud's own ARPACK
#    routines (dnaupd_ etc.) keep void. ───────────────────────────────────
F="$SRC/scipy/sparse/linalg/_eigen/arpack/arnaud/src/blaslapack_declarations.h"
if ! grep -q "int ARNAUD_BLAS(saxpy)(" "$F"; then
  sed -ri 's/^void (ARNAUD_BLAS\([a-z0-9]+\))\(/int \1(/' "$F"
  echo "[scipy-src] arpack arnaud BLAS/LAPACK void -> int"
else
  echo "[scipy-src] arpack arnaud BLAS/LAPACK already patched"
fi

# ── propack BLAS/LAPACK declarations: same class. The vendored PROPACK C
#    tree declares the Fortran BLAS/LAPACK entry points `void
#    BLAS_FUNC(name)(...)`; OpenBLAS defines them int -> wasm-ld trap thunks
#    + marshaling adapters on the svds path (signature_mismatch:*, gate 15).
#    cdotc_/zdotc_ are local static implementations (PROPACK_CPLXF_TYPE/
#    PROPACK_CPLX_TYPE returns), untouched by the void rule. ───────────────
F="$SRC/scipy/sparse/linalg/_propack/PROPACK/src/include/blaslapack_declarations.h"
if ! grep -q "int BLAS_FUNC(saxpy)(" "$F"; then
  sed -ri 's/^void (BLAS_FUNC\([a-z0-9]+\))\(/int \1(/' "$F"
  echo "[scipy-src] propack BLAS/LAPACK void -> int"
else
  echo "[scipy-src] propack BLAS/LAPACK already patched"
fi

# ── integrate/__quadpack.h: the f2py callback glue imports ctypes at CALL
#    time (init_callback) to type-check legacy ctypes callables. wasm has no
#    _ctypes (libffi wasm port is emscripten-only), so quad() with a Python
#    callable raised ModuleNotFoundError at first use (gate 15.3). Guard: on
#    ctypes import failure, skip the legacy type check (cfuncptr_type
#    sentinel); pure-Python callables still work via the PyCapsule path.
#    ctypes-wrapped callables remain unsupported (Stage 13 boundary). ──────
F="$SRC/scipy/integrate/__quadpack.h"
if ! grep -q "WASI ctypes guard" "$F"; then
  python3 - "$F" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """    if (cfuncptr_type == NULL) {
        PyObject *module;

        module = PyImport_ImportModule("ctypes");
        if (module == NULL) {
            return -1;
        }

        cfuncptr_type = PyObject_GetAttrString(module, "_CFuncPtr");
        Py_DECREF(module);
        if (cfuncptr_type == NULL) {
            return -1;
        }
    }

    if (PyObject_TypeCheck(func, (PyTypeObject *)cfuncptr_type)) {"""
new = """    if (cfuncptr_type == NULL) {
        PyObject *module;

        module = PyImport_ImportModule("ctypes");
        if (module == NULL) {
            /* WASI ctypes guard: wasm CPython has no _ctypes (libffi wasm
             * port is emscripten-only). Skip the legacy ctypes-callable
             * type check; pure-Python callables still work via the
             * PyCapsule path. */
            PyErr_Clear();
            cfuncptr_type = Py_None;
        } else {
            cfuncptr_type = PyObject_GetAttrString(module, "_CFuncPtr");
            Py_DECREF(module);
            if (cfuncptr_type == NULL) {
                PyErr_Clear();
                cfuncptr_type = Py_None;
            }
        }
    }

    if (cfuncptr_type != Py_None &&
        PyObject_TypeCheck(func, (PyTypeObject *)cfuncptr_type)) {"""
assert old in s, "__quadpack.h: expected init_callback ctypes block not found"
open(p, "w").write(s.replace(old, new, 1))
PYEOF
  echo "[scipy-src] __quadpack.h init_callback ctypes guard (WASI)"
else
  echo "[scipy-src] __quadpack.h ctypes guard already patched"
fi

echo "[scipy-src] all scipy source patches applied"
