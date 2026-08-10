#!/bin/bash
# SciPy pipeline driver — one commit per layer (see
# design_docs/code_interpreter_wasm_scipy_build.md "Recommended delivery").
# Stages are added here as they land; each is idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">>> scipy-pipeline: Stage 2 (libf2c)..."
bash "$HERE/01-libf2c.sh"

# Stage 3 (OpenBLAS) and later stages append here as implemented.
