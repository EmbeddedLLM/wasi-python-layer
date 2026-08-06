#!/bin/bash
# Build numpy 2.5.1 + pandas 3.0.3 for wasm32-wasip2 (eryx code-interpreter backend), end to end.
#
#   ./build-all.sh            # full build into /tmp/wasi-build
#   WASI_BUILD=/path ./build-all.sh
#   ERYX_PY=/venv/bin/python ./build-all.sh   # also verify in eryx at the end
#
# Stages are idempotent (skip completed steps), so re-running resumes where it left off.
# Full annotated recipe: design_docs/code_interpreter_wasm_numpy251_meson_build.md (numpy/meson)
# and design_docs/code_interpreter_wasm_pandas_build.md (pandas/bypass).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
echo "=== WASI build root: $WASI_BUILD ==="

"$HERE/01-toolchain.sh"      # wasi-sdk + host CPython + wasm CPython + libpython.so + cross-python
"$HERE/02-numpy251.sh"       # numpy 2.5.1 via meson (the eight walls)
"$HERE/03-pandas.sh"         # pandas 3.0.3 via bypass (cythonize + cross-compile)
"$HERE/04-assemble-test.sh"  # assemble numpy + pandas + deps; verify in eryx if ERYX_PY set

echo "=== DONE ==="
echo "site-packages: $WASI_BUILD/combined-site  (numpy 2.5.1 + pandas 3.0.3, wasm32-wasip2)"
