#!/bin/bash
# Package the assembled site-packages into a distributable tarball.
#
#   ./package-tarball.sh                    # uses /tmp/wasi-build/matplotlib-build/mpl-site
#   SITE=/path/to/mpl-site ./package-tarball.sh
#   OUTDIR=./dist ./package-tarball.sh
#
# Produces: $OUTDIR/python-site-packages-cp314-wasm32-wasip2.tar.gz + SHA256SUMS.txt
set -euo pipefail

SITE="${SITE:-/tmp/wasi-build/matplotlib-build/mpl-site}"
OUTDIR="${OUTDIR:-.}"

if [ ! -d "$SITE" ]; then
    echo "ERROR: site-packages directory not found: $SITE"
    echo "Run build-all.sh first, or set SITE=/path/to/mpl-site"
    exit 1
fi

mkdir -p "$OUTDIR"
TARBALL="$OUTDIR/python-site-packages-cp314-wasm32-wasip2.tar.gz"

echo "Packaging: $SITE -> $TARBALL"
tar czf "$TARBALL" -C "$SITE" .
sha256sum "$TARBALL" > "$OUTDIR/SHA256SUMS.txt"

echo "Done:"
ls -lh "$TARBALL"
cat "$OUTDIR/SHA256SUMS.txt"
echo ""
echo "To use locally without downloading:"
echo "  export VR_CODE_INTERPRETER_WASM_SITE_PACKAGES=$TARBALL"
echo "Or extract and point to the directory:"
echo "  mkdir -p /tmp/wasm-site && tar xzf $TARBALL -C /tmp/wasm-site"
echo "  export VR_CODE_INTERPRETER_WASM_SITE_PACKAGES=/tmp/wasm-site"
