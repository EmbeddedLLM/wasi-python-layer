#!/bin/bash
# Build matplotlib 3.11.1 + deps for wasm32-wasip2 (eryx code-interpreter backend).
#
#   ./build-all.sh                          # full build into /tmp/wasi-build
#   WASI_BUILD=/path ./build-all.sh
#   ERYX_PY=/venv/bin/python ./build-all.sh # also verify in eryx
#
# Prerequisites: the pandas-pipeline must have been run first (stages 01-02)
# to provide wasi-sdk-27, wasm CPython 3.14, and numpy 2.5.1.
#
# Full annotated recipe: design_docs/code_interpreter_wasm_matplotlib_build.md
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
export MPL_BUILD="$WASI_BUILD/matplotlib-build"

echo "=== matplotlib WASI build ==="
echo "  WASI_BUILD:  $WASI_BUILD"
echo "  MPL_BUILD:   $MPL_BUILD"

# Verify prerequisites from pandas-pipeline
for req in "$WASI_BUILD/wasi-sdk/bin/clang" \
           "$WASI_BUILD/cpython-wasi/install/lib/libpython3.14.so" \
           "$WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages/numpy/__init__.py"; do
    if [ ! -e "$req" ]; then
        echo "ERROR: prerequisite missing: $req"
        echo "Run the pandas-pipeline first: ../pandas-pipeline/build-all.sh"
        exit 1
    fi
done

"$HERE/01-download.sh"       # download matplotlib, freetype, qhull, contourpy, kiwisolver
"$HERE/02-native-deps.sh"    # cross-compile agg, freetype, qhull, raqm stub
"$HERE/03-extensions.sh"     # build 9 C/C++ extensions
"$HERE/04-assemble-test.sh"  # assemble site-packages + verify in eryx

echo "=== DONE ==="
echo "site-packages: $MPL_BUILD/mpl-site  (matplotlib 3.11.1, wasm32-wasip2)"
