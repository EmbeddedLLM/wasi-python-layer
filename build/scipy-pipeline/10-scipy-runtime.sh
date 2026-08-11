#!/bin/bash
# Stage 14 / M11-M13: runtime functionality gates in the real Eryx sandbox.
# Progressive: top-level import -> ndimage -> linalg (the key milestone) ->
# fft -> optimize -> signal -> sparse. See design_docs
# code_interpreter_wasm_scipy_build.md Stage 14 (13.1-13.7).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SCIPY_SITE="$WASI_BUILD/scipy-build/install/usr/local/lib/python3.14/site-packages"
NUMPY_SITE="$WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages"
ERYX_PY="${ERYX_PY:-$HERE/../../.venv/bin/python}"

test -d "$SCIPY_SITE/scipy" || { echo "[scipy-runtime] scipy not installed — run 09-scipy-build.sh + meson install" >&2; exit 1; }

SITE="$(mktemp -d)"
cp -r "$NUMPY_SITE/numpy" "$SITE/"
cp -r "$SCIPY_SITE/scipy" "$SITE/"
# pyduccfft + _qmc_cy are KEPT (Stage 14 addendum, 2026-08-10): after the
# cxx_eh_stub shrink + relink (minimal stub = only symbols the erics base
# libs can't provide), both modules import and run. scipy 1.18 has NO
# pocketfft fallback — scipy.fft's numpy-input backend is duccfft, and
# `import scipy.signal` eagerly imports scipy.fft, so deleting pyduccfft
# breaks gates 13.4/13.6 outright. The fft/stats import guards in
# patch-scipy-src.sh are harmless belt-and-braces and stay.
# Eryx stdlib supplement: the embedded erics stdlib is a minimal subset
# (argparse/gettext/unittest.case/fileinput missing). Copy the pure-python
# stdlib from the wasm CPython install; sandbox sys.path is stdlib-first, so
# only missing modules are picked up. The exclusion must be anchored — a bare
# `grep -v test` also excludes unittest.
STDLIB="$WASI_BUILD/cpython-wasi/install/lib/python3.14"
for d in $(ls -d "$STDLIB"/*/ 2>/dev/null | grep -vE "site-packages|lib-dynload|__pycache__|(^|/)(test|tests|idlelib|turtledemo)(/|$)"); do
  cp -r "$d" "$SITE/"
done
cp "$STDLIB"/*.py "$SITE/"

"$ERYX_PY" - "$SITE" <<'EOF'
import sys
import eryx

factory = eryx.SandboxFactory(site_packages=sys.argv[1], packages=[], imports=[])
sb = factory.create_sandbox(
    resource_limits=eryx.ResourceLimits(execution_timeout_ms=300000)
)
code = r'''
import numpy as np

# 13.1 top-level
import scipy
assert scipy.__version__ == "1.18.0", scipy.__version__
print("13.1 top-level OK", scipy.__version__)

# 13.2 ndimage
from scipy import ndimage
x = np.zeros((9, 9)); x[4, 4] = 1
y = ndimage.gaussian_filter(x, 1.0)
assert y.shape == (9, 9) and y[4, 4] > y[0, 0]
print("13.2 ndimage OK")

# 13.3 linalg — the key milestone (SciPy -> LAPACK -> OpenBLAS/f2c -> wasm)
from scipy import linalg
A = np.array([[3.0, 1.0], [1.0, 2.0]])
b = np.array([9.0, 8.0])
xs = linalg.solve(A, b)
assert np.allclose(xs, [2.0, 3.0]), xs
print("13.3 linalg.solve OK", xs)

# 13.4 fft
from scipy import fft
yf = fft.fft(np.array([1., 2., 3., 4.]))
assert len(yf) == 4
print("13.4 fft OK")

# 13.5 optimize
from scipy.optimize import minimize_scalar
r = minimize_scalar(lambda t: (t - 3) ** 2)
assert abs(r.x - 3) < 1e-4, r.x
print("13.5 optimize OK", round(r.x, 4))

# 13.6 signal
from scipy.signal import butter, sosfilt
sos = butter(4, 0.2, output="sos")
ys = sosfilt(sos, np.arange(100, dtype=float))
assert ys.shape == (100,)
print("13.6 signal OK")

# 13.7 sparse
from scipy.sparse import csr_matrix
from scipy.sparse.linalg import spsolve
A2 = csr_matrix([[3., 1.], [1., 2.]])
b2 = np.array([9., 8.])
x2 = spsolve(A2, b2)
assert np.allclose(x2, [2., 3.]), x2
print("13.7 sparse OK", x2)

# 13.8 special/stats (design doc Stage 14.8)
from scipy.special import erf
from scipy.stats import norm
assert abs(erf(0.0)) < 1e-12
assert abs(norm.cdf(0.0) - 0.5) < 1e-12
print("13.8 special/stats OK")

# ── Stage 15 coverage (exercises the void->int fixed modules) ──────────────
# linalg.expm — cython_blas path (was trap-thunked)
from scipy.linalg import expm
E = expm(np.array([[1., 1.], [0., 1.]]))
assert E.shape == (2, 2) and np.isfinite(E).all()
print("15.1 linalg.expm OK")

# spatial cKDTree
from scipy.spatial import cKDTree
t = cKDTree(np.array([[0., 0.], [1., 1.], [2., 0.]]))
d, idx = t.query([0.5, 0.5])
assert idx == 0
print("15.2 spatial cKDTree OK")

# integrate quad
from scipy.integrate import quad
v, err = quad(lambda x: x * x, 0, 1)
assert abs(v - 1.0 / 3.0) < 1e-9
print("15.3 integrate quad OK")

# interpolate interp1d (default kind='linear': f(1.5) between (1,1) and (2,4) = 2.5)
from scipy.interpolate import interp1d
f = interp1d([0., 1., 2.], [0., 1., 4.])
assert abs(float(f(1.5)) - 2.5) < 1e-9
print("15.4 interpolate OK")

# cluster vq
from scipy.cluster.vq import vq
code, _ = vq(np.array([[0., 0.], [1., 1.], [2., 0.]]), np.array([[0., 0.], [2., 0.]]))
assert code.shape == (3,)
print("15.5 cluster OK")

# sparse.linalg eigsh — _arpacklib path (was trap-thunked)
from scipy.sparse import diags
from scipy.sparse.linalg import eigsh
vals = eigsh(diags([1., 2., 3., 4., 5.]), k=2)[0]
assert np.allclose(sorted(vals), [4., 5.]), vals
print("15.6 sparse eigsh OK", sorted(vals))

# constants
from scipy import constants
assert abs(constants.speed_of_light - 299792458.0) < 1.0
print("15.7 constants OK")

print(">>> ALL SCIPY RUNTIME GATES PASSED")
'''
r = sb.execute(code)
print(r.stdout)
assert ">>> ALL SCIPY RUNTIME GATES PASSED" in r.stdout, f"gates failed: {r.stderr}"
EOF
rm -rf "$SITE"
