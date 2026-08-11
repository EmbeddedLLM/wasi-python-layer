#!/bin/bash
# Stage 13: guard every top-level `import ctypes` in the shipped scipy tree.
# The wasm CPython has no _ctypes (libffi wasm port is emscripten-only — same
# blocker as cffi), so `import ctypes` raises ModuleNotFoundError at runtime.
# The PyCapsule path in _ccallback stays fully functional; ctypes-callable
# support degrades to a clear ValueError.
# Idempotent: each guard checks for its marker before applying.
# Usage: patch-scipy-ctypes.sh <scipy-src>
set -euo pipefail
SRC="${1:?scipy source dir}"

# ── _ccallback.py: guarded ctypes import + PyCFuncPtr ──────────────────────
F="$SRC/scipy/_lib/_ccallback.py"
if ! grep -q "ctypes = None" "$F"; then
  python3 - "$F" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "import ctypes\n\nPyCFuncPtr = ctypes.CFUNCTYPE(ctypes.c_void_p).__bases__[0]\n",
    "try:\n"
    "    import ctypes\n"
    "    PyCFuncPtr = ctypes.CFUNCTYPE(ctypes.c_void_p).__bases__[0]\n"
    "except (ImportError, AttributeError):  # wasm: no _ctypes (libffi is emscripten-only)\n"
    "    ctypes = None\n"
    "    PyCFuncPtr = None\n",
)
s = s.replace("        elif isinstance(obj, PyCFuncPtr):",
              "        elif PyCFuncPtr is not None and isinstance(obj, PyCFuncPtr):")
s = s.replace("        if isinstance(user_data, ctypes.c_void_p):",
              "        if ctypes is not None and isinstance(user_data, ctypes.c_void_p):")
open(p, "w").write(s)
EOF
  echo "[ctypes] _ccallback.py guarded"
else
  echo "[ctypes] _ccallback.py already guarded"
fi

# ── _ccallback_c.pyx: module-level ctypes test helpers must not break import ─
F="$SRC/scipy/_lib/_ccallback_c.pyx"
if ! grep -q "ctypes = None" "$F"; then
  python3 - "$F" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """# Ctypes declarations of the callables above
import ctypes

plus1_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.POINTER(ctypes.c_int), ctypes.c_void_p)
plus1_ctypes = ctypes.cast(<size_t>&plus1_cython, plus1_t)

plus1b_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.c_double,
                            ctypes.POINTER(ctypes.c_int), ctypes.c_void_p)
plus1b_ctypes = ctypes.cast(<size_t>&plus1b_cython, plus1b_t)

plus1bc_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.c_double, ctypes.c_double,
                            ctypes.POINTER(ctypes.c_int), ctypes.c_void_p)
plus1bc_ctypes = ctypes.cast(<size_t>&plus1bc_cython, plus1bc_t)

sine_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.c_void_p)
sine_ctypes = ctypes.cast(<size_t>&sine, sine_t)
"""
new = """# Ctypes declarations of the callables above (guarded: wasm has no _ctypes)
try:
    import ctypes
except ImportError:
    ctypes = None

if ctypes is not None:
    plus1_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.POINTER(ctypes.c_int), ctypes.c_void_p)
    plus1_ctypes = ctypes.cast(<size_t>&plus1_cython, plus1_t)

    plus1b_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.c_double,
                                ctypes.POINTER(ctypes.c_int), ctypes.c_void_p)
    plus1b_ctypes = ctypes.cast(<size_t>&plus1b_cython, plus1b_t)

    plus1bc_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.c_double, ctypes.c_double,
                                ctypes.POINTER(ctypes.c_int), ctypes.c_void_p)
    plus1bc_ctypes = ctypes.cast(<size_t>&plus1bc_cython, plus1bc_t)

    sine_t = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_double, ctypes.c_void_p)
    sine_ctypes = ctypes.cast(<size_t>&sine, sine_t)
else:
    plus1_t = None
    plus1_ctypes = None
    plus1b_t = None
    plus1b_ctypes = None
    plus1bc_t = None
    plus1bc_ctypes = None
    sine_t = None
    sine_ctypes = None
"""
assert old in s, "_ccallback_c.pyx: expected block not found"
s = s.replace(old, new)
open(p, "w").write(s)
EOF
  echo "[ctypes] _ccallback_c.pyx guarded"
else
  echo "[ctypes] _ccallback_c.pyx already guarded"
fi

# ── stats/_continuous_distns.py: guarded import + c_void_p fallback ────────
F="$SRC/scipy/stats/_continuous_distns.py"
if ! grep -q "_C_VOID_P" "$F"; then
  python3 - "$F" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("import ctypes\n", "try:\n    import ctypes\n    _C_VOID_P = ctypes.c_void_p\nexcept ImportError:  # wasm: no _ctypes\n    ctypes = None\n    _C_VOID_P = None\n", 1)
s = s.replace(".ctypes.data_as(ctypes.c_void_p)", ".ctypes.data_as(_C_VOID_P)")
open(p, "w").write(s)
EOF
  echo "[ctypes] _continuous_distns.py guarded"
else
  echo "[ctypes] _continuous_distns.py already guarded"
fi

# ── io/arff/_arffread.py: guarded import + field-size fallback ─────────────
F="$SRC/scipy/io/arff/_arffread.py"
if ! grep -q "_MAX_FIELD_SIZE" "$F"; then
  python3 - "$F" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("import ctypes\n", "try:\n    import ctypes\n    _MAX_FIELD_SIZE = None\nexcept ImportError:  # wasm: no _ctypes\n    ctypes = None\n    _MAX_FIELD_SIZE = 2**31 - 1\n", 1)
s = s.replace(
    "    csv.field_size_limit(int(ctypes.c_ulong(-1).value // 2))",
    "    if ctypes is not None:\n        csv.field_size_limit(int(ctypes.c_ulong(-1).value // 2))\n    else:\n        csv.field_size_limit(_MAX_FIELD_SIZE)",
)
open(p, "w").write(s)
EOF
  echo "[ctypes] _arffread.py guarded"
else
  echo "[ctypes] _arffread.py already guarded"
fi

echo "[ctypes] scipy ctypes guards applied"
