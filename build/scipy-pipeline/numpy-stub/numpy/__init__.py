# Build-time stub for the cross-python wrapper (PYTHONHOME=wasm): the real
# wasm numpy cannot be imported on the host (its .so is wasm), but meson's
# `np.get_include()` probe needs a numpy that imports, and data-gen scripts
# (scipy/special/utils/makenpz.py) need the full numpy (np.loadtxt).
#
# On first attribute access beyond the stub's own, the stub loads the
# build-venv's HOST numpy AS "numpy" (pre-registered in sys.modules, so its
# internal relative imports resolve) and monkeypatches get_include() to keep
# answering with the WASM numpy's header dir (the wasm numpyconfig.h is
# ABI-critical for the cross-compile).
# Shadowed onto sys.path FIRST by 08-scipy-cross.sh; never shipped.
import importlib.util
import os
import sys

_VERSION = "2.5.1"
_INCLUDE = os.environ.get(
    "NUMPY_INCLUDE",
    "/tmp/wasi-build/numpy251-install/usr/local/lib/python3.14/"
    "site-packages/numpy/_core/include",
)
_REAL_DIR = "/tmp/wasi-build/build-venv/lib/python3.14/site-packages/numpy"
_REAL = None


def _real():
    global _REAL
    if _REAL is None:
        spec = importlib.util.spec_from_file_location(
            "numpy", os.path.join(_REAL_DIR, "__init__.py")
        )
        spec.submodule_search_locations = [_REAL_DIR]
        mod = importlib.util.module_from_spec(spec)
        sys.modules["numpy"] = mod  # pre-register: internal relative imports resolve
        spec.loader.exec_module(mod)
        mod.get_include = lambda: _INCLUDE  # probe must report the wasm headers
        _REAL = mod
    return _REAL


def get_include():
    return _INCLUDE


def __getattr__(name):
    return getattr(_real(), name)


__version__ = _VERSION
