#!/bin/bash
# Package the assembled site-packages tree into the release tarball + SHA256SUMS.txt.
#
# Usage:
#   scripts/package-tarball.sh            # -> dist-wasm/ (tarball + SHA256SUMS.txt)
#   scripts/package-tarball.sh /path/out
#
# Env: WASI_BUILD (default /tmp/wasi-build)
#
# This mirrors the packaging step of .github/workflows/build-release.yml, for
# building + publishing a release locally:
#   gh release create <tag> dist-wasm/python-site-packages-cp314-wasm32-wasip2.tar.gz dist-wasm/SHA256SUMS.txt
set -euo pipefail

WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="$WASI_BUILD/matplotlib-build/mpl-site"
[ -d "$SITE/numpy" ] || {
    echo "ERROR: $SITE is not the assembled site-packages tree (run scripts/wasm_setup.sh first)." >&2
    exit 1
}

OUT="${1:-dist-wasm}"
mkdir -p "$OUT"
TARBALL="$OUT/python-site-packages-cp314-wasm32-wasip2.tar.gz"

echo "Packaging $SITE -> $TARBALL"
tar czf "$TARBALL" -C "$SITE" .
sha256sum "$TARBALL" > "$OUT/SHA256SUMS.txt"
ls -lh "$TARBALL"
cat "$OUT/SHA256SUMS.txt"

echo ""
echo "Publish with:"
echo "  gh release create <tag> $TARBALL $OUT/SHA256SUMS.txt"
