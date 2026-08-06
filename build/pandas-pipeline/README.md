# WASI pandas pipeline (numpy 2.5.1 + pandas 3.0.3, wasm32-wasip2)

Reproducible build of a **pandas 3.0.3** that runs in the eryx WASM code-interpreter backend
(wasi-sdk-27 / `wasm32-wasip2`, eryx 0.5.0). Verified: `import pandas`, `Series`, and **`DataFrame`**
(groupby, sort, filter, apply, describe, value_counts, CSV round-trip) all run correctly in eryx.

**Read the worklogs first** (the hard-won lessons):
- `design_docs/code_interpreter_wasm_numpy251_meson_build.md` — numpy 2.5.1 via meson; the **eight**
  meson cross-compilation walls and their fixes.
- `design_docs/code_interpreter_wasm_pandas_build.md` — pandas via the bypass; ABI fixes
  (`npy_int64`/ILP32, C++ EH stub, stdlib gaps), the numpy C-API skew and its solution.
- `design_docs/code_interpreter_wasm_numpy_build.md` — the wasm CPython + setup.py numpy recipe
  (stage 1 below).

## Run

```bash
./build-all.sh                       # full build into /tmp/wasi-build (~30-40 min first run)
WASI_BUILD=/some/dir ./build-all.sh  # custom build root
ERYX_PY=/venv/bin/python ./build-all.sh   # also verify in eryx (needs a venv with pyeryx)
```

Stages are idempotent — re-running resumes where it left off.

> **Verified (2026-07-21):** stages 1–4 run end-to-end and reproduce a working build —
> `02` builds numpy 2.5.1 (meson), `03` builds all 44 pandas `_libs` (44 ok / 0 failed), and
> `04` assembles + verifies in eryx: `[numpy] NUMPY_OK 2.5.1`, `[pandas] PANDAS_OK 3.0.3`,
> `ALL_WASM_PACKAGES_OK`. (Stage 1's CPython build sub-steps were proven individually; the script
> is idempotent and syntax-checked. A from-scratch `WASI_BUILD=/fresh ./build-all.sh` reproduces it.)

## What each stage does

| stage | script | produces |
|---|---|---|
| 1 | `01-toolchain.sh` | wasi-sdk-27; native host CPython 3.14; **wasm CPython 3.14** (`CROSS_PREFIX`: `libpython3.14.so` + headers + sysconfigdata, from the `dicej/cpython` fork == eryx's exact commit); `cross-python.sh` |
| 2 | `02-numpy251.sh` | **numpy 2.5.1** for wasm via **meson** → `numpy251-install/…/site-packages/numpy` |
| 3 | `03-pandas.sh` | **pandas 3.0.3** `_libs` via the **bypass** (cythonize natively + cross-compile) → `pandas/pandas-wasi/pandas` |
| 4 | `04-assemble-test.sh` | `combined-site/` (numpy + pandas + dateutil/pytz/tzdata/six + `mmap.py` stub); verifies in eryx |

## The two build strategies (and why both)

- **numpy 2.5.1 → meson.** numpy 2.x is meson-python, so we cross meson's cross-compilation walls
  (patching meson + numpy). Needed because pandas must run against a numpy whose **C-API table
  matches** what pandas was compiled against — a one-version skew traps `DataFrame`.
- **pandas → bypass.** Rather than cross pandas' own meson build, we **cythonize natively and
  cross-compile the `.c`** with the proven wasi-sdk-27 flags (the numpy/Pillow lever). pandas'
  extension list is read from its `meson.build` (`build_pandas_libs.py`).

## Files

- `build-all.sh` — orchestration.
- `01-toolchain.sh` … `04-assemble-test.sh` — the four stages.
- `build_pandas_libs.py` — the pandas bypass engine (cythonize + cross-compile all `_libs`).
- `cross-python.sh.in` — template for the host-python-reports-wasm-sysconfig wrapper.
- `cxx_eh_stub.c` — C++ exception ABI stub (wasi-sdk-27 libc++abi has no exceptions).
- `mmap.py` — `mmap` stub (no mmap on wasm).
- `test_packages.py` — eryx verification (numpy + pandas ops).
- `patches/` — the fiddly patches, each an idempotent, annotated script:
  - `patch-pyconfig-wasm32.sh` — host `pyconfig.h` → wasm32 sizes (meson Wall 2).
  - `patch-numpy-temp-elide.sh` — `dladdr` guard `!defined(__wasi__)` (Wall 7).
  - `patch-numpy-meson.sh` — `find_installation`→cross-python (Wall 3) + C++ EH stub (Wall 9).
  - `patch-meson-clike.sh` — skip `--start-group` for wasm (Wall 8; clears meson `__pycache__`).
  - `patch-pandas-ctypes.sh` — make pandas' `import ctypes` optional (no `_ctypes` on wasm).

## Prerequisites

`curl`, `git`, a native C toolchain (`gcc`, `make`), `python3` (for the patch scripts), and ~5 GB
disk. Network access (downloads wasi-sdk, CPython, numpy, pandas, deps). Verification needs a venv
with `pyeryx` (`ERYX_PY`).
