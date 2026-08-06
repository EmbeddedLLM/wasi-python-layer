#!/bin/bash
# soundfile-pipeline — cross-compile libsndfile + _soundfile_native for wasm32-wasip2.
#
#   ./build-all.sh                          # full build into $WASI_BUILD
#   WASI_BUILD=/path ./build-all.sh
#
# Prerequisites: the pandas-pipeline 01-toolchain.sh must have been run first
# (wasi-sdk-27, wasm CPython 3.14 install, cmake+ninja venv) — same as the
# matplotlib-pipeline.
#
# Full annotated recipe: design_docs/code_interpreter_wasm_soundfile_build.md
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"

echo "=== soundfile WASI build ==="
echo "  WASI_BUILD: $WASI_BUILD"

bash "$HERE/02-libsndfile.sh"
bash "$HERE/03-extension.sh"
bash "$HERE/04-assemble-test.sh"

echo "=== soundfile WASI build complete ==="
