#!/bin/bash
# Strip host-platform C extensions from an assembled site-packages tree.
#
# Pure-python wheels can ship host-compiled extensions (fonttools 4.63.0 ships
# qu2cu.cpython-314-x86_64-linux-gnu.so since its cp314 platform wheels landed);
# the wasm guest cannot late-link them and the pure-Python fallback takes over.
# Wasm extensions carry the wasm32-wasi suffix and are preserved (as are
# extension-less native libs like libsndfile.so).
#
# Usage: build/strip-host-extensions.sh <site-dir>
set -euo pipefail
SITE="${1:?usage: strip-host-extensions.sh <site-dir>}"
N=$(find "$SITE" -type f \( \
    -name "*-x86_64-linux-gnu.so" -o -name "*-aarch64-linux-gnu.so" \
    -o -name "*-x86_64-apple-darwin.so" -o -name "*-aarch64-apple-darwin.so" \
    -o -name "*.pyd" \) -print -delete | wc -l)
[ "$N" -eq 0 ] || echo "  [strip] removed $N host-platform extension(s)"
