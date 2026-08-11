#!/bin/bash
# Stage 5 / M5: P11 ABI gate on _blas_smoke (and, later, SciPy sources +
# generated Cython output — plan Stage 12). Two checks:
#   1. -Wcast-function-type-strict must be clean (enforced -Werror in 03).
#   2. structural sweep: no 1-arg METH_NOARGS/getset handlers.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[abi-gate] structural sweep (P11)..."
"$HERE/abi_sweep.py" "$HERE/smoke/_blas_smoke.c"

echo "[abi-gate] PASS: no incompatible CPython function-pointer signatures"
