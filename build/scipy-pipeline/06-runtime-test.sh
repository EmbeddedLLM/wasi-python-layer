#!/bin/bash
# Stage 6 / M6-M7: execute _blas_smoke in the real Eryx sandbox.
# DGEMM must return (19.0, 22.0, 43.0, 50.0); DGESV (2.0, 3.0).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
BUILD="$WASI_BUILD/scipy-build"
EXT="$BUILD/build/_blas_smoke.cpython-314-wasm32-wasi.so"
ERYX_PY="${ERYX_PY:-$HERE/../../.venv/bin/python}"

if [ ! -f "$EXT" ]; then
  echo "[blas-smoke] extension missing — run 03-blas-smoke.sh first" >&2
  exit 1
fi

SITE="$(mktemp -d)"
cp "$EXT" "$SITE/"

"$ERYX_PY" - "$SITE" <<'EOF'
import sys
import eryx

factory = eryx.SandboxFactory(site_packages=sys.argv[1], packages=[], imports=[])
sb = factory.create_sandbox(
    resource_limits=eryx.ResourceLimits(execution_timeout_ms=120000)
)
r = sb.execute(
    "import _blas_smoke as m\n"
    "print('DGEMM', m.dgemm())\n"
    "print('DGESV', m.dgesv())\n"
)
print(r.stdout)
assert "(19.0, 22.0, 43.0, 50.0)" in r.stdout, f"DGEMM wrong: {r.stdout} {r.stderr}"
assert "(2.0, 3.0)" in r.stdout, f"DGESV wrong: {r.stdout} {r.stderr}"
print(">>> _blas_smoke runtime gate PASSED (DGEMM + DGESV in Eryx)")
EOF
rm -rf "$SITE"
