#!/bin/bash
# Stage 16/17 / M15-M16: production-factory lazy SciPy import + pre-init budget.
#
# Stage 16 gate: scipy works in the full production factory WITHOUT being
# blanket pre-imported — lazy first-use import, no eager-import coupling into
# numpy-only workloads.
#
# Stage 17 measurements (design doc): factory build success, Wizer fuel usage
# (pre-import failures), factory build time, snapshot size, sandbox startup,
# first-scipy-import latency — across A (no pre-import / default), B (import
# scipy), C (selected lightweight submodules). Do not assume more pre-imports
# are better.
#
# Usage:
#   bash 12-factory-lazy.sh [site-dir]
#     site-dir  default: $WASI_BUILD/matplotlib-build/mpl-site (must contain scipy)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${1:-$WASI_BUILD/matplotlib-build/mpl-site}"
ERYX_PY="${ERYX_PY:-$HERE/../../.venv/bin/python}"

test -d "$SITE/scipy" || {
  echo "[factory-lazy] scipy not in $SITE — run 11-assemble.sh first" >&2
  exit 1
}

"$ERYX_PY" - "$SITE" <<'EOF'
import os
import sys
import time

import eryx

site = sys.argv[1]


def sandbox_code(body: str) -> str:
    return body


# ── shared workload bodies ──────────────────────────────────────────────────
NUMPY_ONLY = r'''
import numpy as np
import sys
assert "scipy" not in sys.modules, "scipy eagerly imported by numpy-only workload"
x = np.arange(12.0).reshape(3, 4)
y = x @ x.T
assert y.shape == (3, 3) and abs(float(y[0, 0]) - 14.0) < 1e-12
print("numpy-only OK (scipy in sys.modules:", "scipy" in sys.modules, ")")
'''

SCIPY_FUNC = r'''
import time
import numpy as np
t0 = time.time()
import scipy
t_import = time.time() - t0
assert scipy.__version__ == "1.18.0", scipy.__version__
from scipy import linalg
from scipy import ndimage
A = np.array([[3.0, 1.0], [1.0, 2.0]])
b = np.array([9.0, 8.0])
xs = linalg.solve(A, b)
assert np.allclose(xs, [2.0, 3.0]), xs
x = np.zeros((9, 9)); x[4, 4] = 1
y = ndimage.gaussian_filter(x, 1.0)
assert y.shape == (9, 9) and y[4, 4] > y[0, 0]
print(f"scipy lazy import OK ({t_import*1000:.0f} ms); solve {xs.tolist()}")
'''


def snapshot_size_bytes(factory) -> int:
    """Serialize the factory to a temp file and report its size."""
    import tempfile

    fd, path = tempfile.mkstemp(prefix="factory-size-", suffix=".bin")
    os.close(fd)
    try:
        factory.save(path)
        return os.path.getsize(path)
    finally:
        os.unlink(path)


def run_case(label: str, imports: list[str], code: str) -> None:
    t0 = time.time()
    factory = eryx.SandboxFactory(
        site_packages=site, packages=[], imports=imports
    )
    t_build = time.time() - t0
    size = snapshot_size_bytes(factory)
    t0 = time.time()
    sb = factory.create_sandbox(
        resource_limits=eryx.ResourceLimits(execution_timeout_ms=300000)
    )
    t_start = time.time() - t0
    t0 = time.time()
    r = sb.execute(code=code)
    t_call = time.time() - t0
    print(f"[{label}] factory build {t_build:.1f}s | snapshot {size/1e6:.1f} MB "
          f"| create_sandbox {t_start*1000:.0f} ms | execute {t_call*1000:.0f} ms")
    print(f"[{label}] stdout: {r.stdout.strip()!r}")


# ── Stage 16: the default policy (no scipy pre-import) ─────────────────────
print("=== Stage 16: lazy first-use import (default policy: imports=[]) ===")
run_case("A", [], NUMPY_ONLY)
run_case("A", [], SCIPY_FUNC)
print("=== Stage 16 gate: PASS — scipy imports lazily, numpy-only workloads "
      "never see it ===")

# ── Stage 17: measure the pre-import variants ──────────────────────────────
print("=== Stage 17: pre-import variants (do not assume more is better) ===")
for label, mods in [("B import scipy", ["scipy"]),
                    ("C submodules", ["scipy", "scipy.linalg", "scipy.ndimage"])]:
    try:
        run_case(label, mods, SCIPY_FUNC)
    except eryx.InitializationError as exc:
        msg = str(exc).strip().splitlines()[-1][:160]
        print(f"[{label}] FACTORY BUILD FAILED: {msg}")
        print(f"[{label}] => pre-import infeasible (wizer pre-init fuel); lazy is required")
print("=== Stage 17 done ===")
EOF