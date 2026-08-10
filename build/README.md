# build/ — wasm32-wasip2 wheel build pipelines

Cross-compiles Python packages for `wasm32-wasip2` with **wasi-sdk-27** (the
exact toolchain the eryx runtime ships; newer wasi-sdk releases do not
late-link — `unresolved symbol __wasi_init_tp`).

## Pipelines (each idempotent, resumes where it left off)

| Pipeline | Builds | Output |
|---|---|---|
| `pandas-pipeline/` | wasi-sdk-27, dicej/cpython fork (`v3.14.0-wasi-sdk-27`), host CPython 3.14, wasm CPython 3.14, numpy 2.5.1 (meson), pandas 3.0.3 (bypass) | `$WASI_BUILD/combined-site` |
| `matplotlib-pipeline/` | matplotlib 3.11.1 + contourpy, kiwisolver (METH_NOARGS/getset arity patches), Pillow (T1 image formats + wasi_heif), cycler, dateutil, fonttools, … | `$WASI_BUILD/matplotlib-build/mpl-site` |
| `soundfile-pipeline/` | libsndfile + `_soundfile_native` | appends to `mpl-site` |
| `extras/` | 01-pure-wheels, 02-regex, 03-audioop, 04-pyyaml, 05-orjson, 06-tiktoken, 07-skimage, 08-opencv | appends to `mpl-site` |
| `assemble-extra.sh` | lxml (05-lxml.sh) + bs4 + the extras set | appends to `mpl-site` |

`scripts/wasm_setup.sh` at the repo root drives the whole chain:
pandas → matplotlib → soundfile → assemble-extra. The final assembled tree is
`$WASI_BUILD/matplotlib-build/mpl-site`, which is exactly what
`.github/workflows/build-release.yml` packages into the release tarball.

`Makefile` / `numpy/` / `pillow/` are the original standalone numpy+Pillow
targets, superseded by the pipelines but kept for reference.

## Environment

- `WASI_BUILD` — build root (default `/tmp/wasi-build`)
- Pipelines need a native toolchain (curl, git, gcc, make) to build the host
  CPython that runs the cross-compile's codegen, plus **jq** (the extras
  scripts resolve PyPI sdist/wheel URLs with it), **unzip** (wheel extraction
  in extras/01 + 07), and **cmake/ninja** (pinned via pip into the build venv).
- `assemble-extra.sh` needs a venv python for `pip download` of pure wheels.
