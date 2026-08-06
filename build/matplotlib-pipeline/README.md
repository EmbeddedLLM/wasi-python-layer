# matplotlib WASI Build Pipeline

Cross-compiles **matplotlib 3.11.1** (+ contourpy, kiwisolver) for `wasm32-wasip2`,
targeting the [eryx](https://docs.eryx.run) WASM sandbox used by our code interpreter.

## Prerequisites

Run the **pandas-pipeline** first (`../pandas-pipeline/build-all.sh`) to provide:
- wasi-sdk-27 toolchain
- wasm CPython 3.14 (`libpython3.14.so`)
- numpy 2.5.1 (wasm)
- Pillow (wasm, optional but needed for `matplotlib.colors`)

## Usage

```bash
./build-all.sh                          # full build into /tmp/wasi-build
WASI_BUILD=/path ./build-all.sh         # custom build root
ERYX_PY=/venv/bin/python ./build-all.sh # also verify in eryx
```

## Stages

| Stage | Script | What it does |
|-------|--------|-------------|
| 1 | `01-download.sh` | Download matplotlib, freetype, qhull, contourpy, kiwisolver |
| 2 | `02-native-deps.sh` | Cross-compile agg, freetype, qhull_r, raqm stub |
| 3 | `03-extensions.sh` | Build 9 C/C++ extensions (pybind11/cppy bypass) |
| 4 | `04-assemble-test.sh` | Assemble site-packages + verify in eryx |

## Key technical decisions

See `design_docs/code_interpreter_wasm_matplotlib_build.md` for the full worklog.

1. **Fake `setjmp.h`** — eryx's wizer rejects wasm EH instructions. freetype/qhull
   use setjmp for error recovery; we stub it (setjmp returns 0, longjmp traps).
2. **Raw CPython `__getattr__`** — pybind11's module `__getattr__` throws
   `AttributeError` via C++ exception. We replace it with a `PyCFunction` that
   uses `PyErr_SetString + return NULL`.
3. **raqm stub** — replaces harfbuzz+sheenbidi+raqm with a minimal LTR glyph
   layout (~120 lines C). Sufficient for ASCII/Latin plot labels.
4. **`sitecustomize.py`** — extends `encodings.__path__` to include our
   site-packages encodings (eryx's stdlib lacks `utf-16-be` needed by fonttools).
5. **Stdlib supplements** — bulk-copy pure-Python stdlib from wasm CPython
   (eryx's bundled stdlib is missing `shlex`, `html`, `unittest`, `argparse`, etc.).

## Known limitations

- C++ exceptions trap on invalid input (pybind11 `throw` → `unreachable`)
- No complex text shaping (raqm stub = LTR only)
- No Axes3D (mplot3d import fails)
- `MPLCONFIGDIR` must be set to a writable directory for font cache
