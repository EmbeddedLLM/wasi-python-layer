# Releases

Tag → sha256 for the `python-site-packages-cp314-wasm32-wasip2.tar.gz` assets.
Populate after each release build (sha printed by `build-release.yml` /
`SHA256SUMS.txt`).

| Tag | SHA256 | Built by |
|-----|--------|----------|
| v1.0.0 | `91859abfdd1820447bf3717f2b286fc585512f125bf5dbc57d68bc9bd875a283` | re-cut 2 (2026-08-12): Tier A perf — zlib + Pillow _imaging at `-O3 -msimd128` (PNG encode path; measured savefig -38%), scipy at `-O3 -msimd128` + meson `buildtype=release` (was debug/-O0) + `DUCC0_NO_LOWLEVEL_THREADING`. Requires pyeryx >= v0.5.0-instance-cap.2 (wasmparser instance cap 4096 + ERYX_HOSTCALL_FUEL_MB raise). Re-cut 1 (2026-08-11): + scipy 1.18.0 (f2c/OpenBLAS ABI) + full skimage scipy-dependent surface + decompositions baked |
