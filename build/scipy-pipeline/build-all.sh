#!/bin/bash
# SciPy pipeline driver — one commit per layer (see
# design_docs/code_interpreter_wasm_scipy_build.md "Recommended delivery").
# Stages are added here as they land; each is idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">>> scipy-pipeline: Stage 2 (libf2c)..."
bash "$HERE/01-libf2c.sh"

echo ">>> scipy-pipeline: Stage 3 (OpenBLAS)..."
bash "$HERE/02-openblas.sh"

echo ">>> scipy-pipeline: Stage 4 (blas smoke)..."
bash "$HERE/03-blas-smoke.sh"

echo ">>> scipy-pipeline: Stage 5 (P11 ABI gate)..."
bash "$HERE/05-abi-gate.sh"

echo ">>> scipy-pipeline: Stage 6 (Eryx runtime gate)..."
bash "$HERE/06-runtime-test.sh"

echo ">>> scipy-pipeline: Stage 7 (SciPy prep: sha-pinned sdist + build venv)..."
bash "$HERE/07-scipy-prep.sh"

echo ">>> scipy-pipeline: Stage 8-9 (source patches + meson cross setup)..."
bash "$HERE/08-scipy-cross.sh"

echo ">>> scipy-pipeline: Stage 11 (meson compile + install)..."
bash "$HERE/09-scipy-build.sh"

echo ">>> scipy-pipeline: Stage 14 (Eryx runtime gates 13.1-13.7)..."
bash "$HERE/10-scipy-runtime.sh"

echo ">>> scipy-pipeline: ALL STAGES DONE (M2-M16 gates green)"
echo "    Clean rebuild: rm -rf \$WASI_BUILD/scipy-1.18.0/build \$WASI_BUILD/scipy-build/install"
echo "    then re-run build-all.sh (stages are idempotent; 09 does a fresh install)."
