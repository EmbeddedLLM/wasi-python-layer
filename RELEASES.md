# Releases

Tag → sha256 for the `python-site-packages-cp314-wasm32-wasip2.tar.gz` assets.
Populate after each release build (sha printed by `build-release.yml` /
`SHA256SUMS.txt`).

| Tag | SHA256 | Built by |
|-----|--------|----------|
| v1.0.0 | `0132e1cacf994216856db0784368e9854123553d2d38fdefe8190b714cdb1089` | re-cut (2026-08-11): + scipy 1.18.0 (f2c/OpenBLAS ABI, full linalg/ndimage/fft/optimize/signal/sparse/special/stats/spatial/integrate/interpolate/cluster/constants surface) + full scikit-image scipy-dependent surface re-enabled + skimage decompositions baked (erics VFS np.load gap). Requires pyeryx >= v0.5.0-instance-cap.1 (wasmparser instance cap 4096) — the layer is 246 native extensions, over the stock ~230-extension cap |
