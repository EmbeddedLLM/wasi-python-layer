#!/bin/bash
# Build the wasm32-wasip2 Python site-packages layer from scratch.
#
# Usage:
#   scripts/wasm_setup.sh            # full from-scratch build (~60 min, ~6GB disk)
#   WASI_BUILD=/path scripts/wasm_setup.sh   # custom build root
#
# Output: the assembled site-packages tree at
#   $WASI_BUILD/matplotlib-build/mpl-site
# which is exactly what the release tarball packages (see build-release.yml).
#
# Requires a venv at $REPO/.venv/bin/python (assemble-extra uses it to fetch
# pure wheels with pip). The CI gate creates it:
#   python -m venv .venv && .venv/bin/pip install pyeryx
#
# Stages are idempotent: re-running resumes where it left off, so incremental
# rebuilds only pay for the changed stage.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
MPL="$WASI_BUILD/matplotlib-build"
BUILD_SITE="$MPL/mpl-site"
PY="$REPO/.venv/bin/python"

[ -x "$PY" ] || { echo "ERROR: $PY not found. Create the venv first (see header)."; exit 1; }

echo "=== WASI site-packages layer build ==="
echo "  Build root:  $WASI_BUILD"
echo "  Output:      $BUILD_SITE"
echo ""

# 1: pandas pipeline (wasi-sdk + wasm CPython 3.14 + numpy 2.5.1 + pandas 3.0.3,
#    assembled into $WASI_BUILD/combined-site)
if [ ! -d "$WASI_BUILD/combined-site/pandas" ]; then
    echo ">>> [1/4] pandas pipeline (toolchain + numpy + pandas)..."
    bash "$REPO/build/pandas-pipeline/build-all.sh"
else
    echo ">>> [skip] pandas pipeline"
fi

# 2: matplotlib + deps (assembles numpy + pandas from combined-site into BUILD_SITE)
if [ ! -d "$BUILD_SITE/matplotlib" ]; then
    echo ">>> [2/4] matplotlib pipeline..."
    bash "$REPO/build/matplotlib-pipeline/build-all.sh"
else
    echo ">>> [skip] matplotlib"
fi

# 3: soundfile (libsndfile + _soundfile_native, assembles into BUILD_SITE)
if [ ! -d "$BUILD_SITE/soundfile" ]; then
    echo ">>> [3/4] soundfile..."
    bash "$REPO/build/soundfile-pipeline/build-all.sh"
else
    echo ">>> [skip] soundfile"
fi

# 4: lxml + bs4 + extras (idempotent per-package)
echo ">>> [4/4] lxml + bs4 + extras..."
bash "$REPO/build/assemble-extra.sh" "$BUILD_SITE" "$MPL" "$PY"

echo ""
echo "=== DONE ==="
echo "Assembled site-packages: $BUILD_SITE"
echo "Package it with: tar czf python-site-packages-cp314-wasm32-wasip2.tar.gz -C \"$BUILD_SITE\" ."
