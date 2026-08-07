# wasi-python-layer

Builds and publishes the **wasm32-wasip2 Python site-packages layer** — a
single, arch-independent tarball of Python packages (numpy, pandas, matplotlib,
soundfile, Pillow, lxml, bs4, sympy, regex, orjson, tiktoken, scikit-image,
opencv, …) cross-compiled from source for the WASI guest runtime.

This repo is **artifacts only**: the build pipelines, the CI, and the release.
There is no interpreter, no sandbox host, and no consumer code here. Consumers
download the tarball over HTTP, pin `{tag, sha256}`, and mount it into their
guest at `/site-packages`.

> **What "layer" means here:** a versioned, mountable dependency bundle — the
> same shape as a Docker/Lambda layer, but it is **not** a container layer or a
> Lambda layer zip. It is a plain site-packages tree.

## Consumption contract

```
https://github.com/EmbeddedLLM/wasi-python-layer/releases/download/<tag>/
├── python-site-packages-cp314-wasm32-wasip2.tar.gz   # wasm32-wasip2 site-packages
└── SHA256SUMS.txt                                    # <sha256>  <filename>
```

- The tarball contains the site-packages tree **directly** (top-level
  `numpy/`, `matplotlib/`, …) — extract in place, no wrapper directory.
- The ABI tag (`cp314`) is part of the filename; the version is the release
  tag. Pin both, plus the sha, in your consumer.
- `wasm32-wasip2` is arch-independent: one tarball serves x86_64 and arm64
  hosts. Host-arch artifacts (the runtime factory/preinit snapshot) are built
  at provision time by the consumer, never shipped here.

## What's in the layer

The tarball is the guest's `site-packages` for CPython **3.14 / wasm32-wasip2**
(extension suffix `.cpython-314-wasm32-wasi.so`; the tree itself is
host-arch-independent). Contents:

**Scientific stack:** numpy 2.5.1 (meson) · pandas 3.0.3 (bypass) · matplotlib
3.11.1 (Agg backend) + contourpy, kiwisolver, cycler, fonttools, packaging,
pyparsing, python-dateutil, pytz, tzdata · scikit-image (51 Cython modules) ·
opencv 4.12.0 (`cv2`: core, imgproc, imgcodecs, objdetect, features2d, calib3d,
flann + python3 module)

**I/O & parsing:** Pillow · soundfile (libsndfile + `_soundfile_native`) ·
lxml 6.0.0 (etree, objectify, sax) · beautifulsoup4 4.15.0 + soupsieve +
typing_extensions · regex · pyyaml 6.0.3 (pure fallback) · ruamel.yaml ·
simplejson · audioop (audioop-lts)

**Serialization / tokens:** orjson 3.11.9 (Rust, wasm32-wasip1 cdylib) ·
tiktoken (Rust + baked-in vocab data)

**Symbolic:** sympy 1.14.0 + mpmath

**Guest environment:** stdlib supplements (missing codecs, mmap stub) ·
`sitecustomize.py` (sets `MPLCONFIGDIR`, extends `encodings.__path__`) ·
`.mpl-config` (matplotlib cache dir — must ship in the tree, the mount is
read-only)

The guest import gate (`scripts/verify-imports.py`) asserts the full set
pre-imports at factory build and imports at runtime.

## Limitations

- **httpx/requests are NOT in the layer.** They are consumer-provisioned pure
  wheels: consumers pin and bundle their own network-client versions into
  their factory, so they own the network contract and versions.
- **networkx is excluded** — it needs `bz2`/`_bz2`, absent from the wasm build.
- **scikit-image is scipy-free only at the top level** — `util`, `draw`,
  `exposure`, `_shared` work; `color`, `io`, and the scipy-dependent submodules
  (`transform`, `restoration`, `graph`, …) raise on use because scipy is not
  buildable for wasm32-wasip2 (BLAS/LAPACK). The functional sweep
  (`scripts/verify-functionality.py`) pins the verified set.
- **imageio ships in the tree and imports from the mount, but is not
  gate-asserted** (skimage.io is out of scope).
- **pyyaml is pure-Python fallback only** — no `_yaml` C extension (documented
  upgrade path: libyaml + `_yaml.c` via the lxml pattern).
- **matplotlib: Agg backend only** — no interactive backends; the font cache is
  read-only (in-memory font scan; cache *writes* are best-effort and may warn).
- **`/site-packages` is mounted read-only** — packages cannot write into their
  own tree; use `/tmp` (writable at runtime) for scratch files.
- **No implicit networking** — egress requires the consumer's proxy/network
  configuration; imports never open sockets.
- **Python ABI is fixed at cp314** — the tarball name carries it
  (`cp314-wasm32-wasip2`); a CPython bump is a new artifact, not an update.

## Building

From scratch (~60 min, ~6 GB):

```bash
python -m venv .venv && .venv/bin/pip install pyeryx   # gate runtime pin
bash scripts/wasm_setup.sh
# -> $WASI_BUILD/matplotlib-build/mpl-site   (the assembled site-packages)
```

Stages are idempotent — re-runs resume where they left off. The guest import
gate (scripts/verify-imports.py) asserts the assembled tree executes in a wasm
guest; it runs in CI on every PR touching `build/**`, `scripts/**`, or the
workflows.

## Releasing

1. Push to `main`.
2. Dispatch **Build WASI Python Layer** (`build-release.yml`) with the tag
   input (e.g. `v1.0.1`), or publish a release to trigger it.
3. The workflow builds the tarball, uploads it + `SHA256SUMS.txt` to the
   release, and prints the sha.
4. Record the tag → sha in `RELEASES.md`.

The build root (`/tmp/wasi-build`, ~6 GB) is cached across runs keyed on the
pipeline content, so full rebuilds take ~45 min and incremental ones minutes.

To build + publish locally instead (e.g. for a fast v1): run `wasm_setup.sh`,
`tar czf python-site-packages-cp314-wasm32-wasip2.tar.gz -C $WASI_BUILD/matplotlib-build/mpl-site .`,
then `gh release create <tag> <tarball> SHA256SUMS.txt`.

## Runtime pin

The gate builds an eryx `SandboxFactory` from the assembled tree, so the CI
pins a pyeryx release wheel from the org's eryx repo (see
`source-gate.yml`). Bump that pin together with the consumers' runtime pin.
