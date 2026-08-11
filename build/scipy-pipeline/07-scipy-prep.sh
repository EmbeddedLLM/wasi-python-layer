#!/bin/bash
# Stage 7 / M8: prepare SciPy 1.18.0 for the WASI cross build.
# - sha256-pinned sdist from PyPI
# - extract to $WASI_BUILD/scipy-1.18.0
# - verify the host build venv (meson>=1.5, ninja, cython) exists
# Reuses the existing cross infra: cross-python.sh, cpython-wasi install,
# numpy 2.5.1 wasm install, host pyconfig patches. No parallel Python
# cross-build mechanism (see design_docs/code_interpreter_wasm_scipy_build.md
# Stage 7).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
BUILD="$WASI_BUILD/scipy-build"
SRC="$WASI_BUILD/scipy-1.18.0"
TARBALL="$WASI_BUILD/scipy-1.18.0.tar.gz"
SCIPY_SHA256="67b2ad2ad54c72ca6d04975a9b2df8c3638c34ddd5b28738e94fc2b57929d378"
URL="https://files.pythonhosted.org/packages/a7/25/c2700dfaf6442b4effaa91af24ebce5dc9d31bb4a69706313aae70d72cd0/scipy-1.18.0.tar.gz"

mkdir -p "$BUILD"

# ── download (sha256-pinned) ───────────────────────────────────────────────
if [ ! -f "$TARBALL" ]; then
  echo "[scipy-prep] downloading scipy 1.18.0 sdist"
  curl -fL "$URL" -o "$TARBALL"
fi
echo "$SCIPY_SHA256  $TARBALL" | sha256sum -c -

# ── extract ────────────────────────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
  tar xzf "$TARBALL" -C "$WASI_BUILD"
fi
test -f "$SRC/meson.build"

# ── build venv (shared with the layer's other pipelines) ───────────────────
if [ ! -x "$WASI_BUILD/build-venv/bin/meson" ]; then
  echo "[scipy-prep] creating build-venv (meson/ninja/cython)" >&2
  "$WASI_BUILD/cpython-host/install/bin/python3.14" -m venv "$WASI_BUILD/build-venv"
  "$WASI_BUILD/build-venv/bin/pip" install -q "meson>=1.5,<2" ninja "cython==3.0.12"
fi
MVER="$("$WASI_BUILD/build-venv/bin/meson" --version)"
echo "[scipy-prep] meson $MVER (need >= 1.5.0)"
echo "[scipy-prep] OK: $SRC"
