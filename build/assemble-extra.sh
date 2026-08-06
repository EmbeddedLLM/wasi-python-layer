#!/bin/bash
# Assemble the "extra" packages (lxml, bs4, extras/01-08) into a site-packages dir.
#
# Shared by the two provisioning tracks so they produce identical contents:
#   - scripts/wasm_setup.sh        (from-scratch track: after pandas/matplotlib/soundfile)
#   - .github/workflows/wasm-artifacts.yml  (artifact track: the release tarball)
#
# The core (numpy, pandas, matplotlib, Pillow, soundfile, ...) is assembled into the
# SAME dir by the pandas/matplotlib/soundfile pipeline build-all scripts; this script
# appends lxml + bs4 + the extras set on top.
#
# Usage:
#   bash build/assemble-extra.sh <site-dir> [matplotlib-build-dir] [python]
#     site-dir        the site-packages dir to append into (e.g. $WASI_BUILD/matplotlib-build/mpl-site)
#     matplotlib-build-dir  default: $WASI_BUILD/matplotlib-build
#     python          default: python3  (used for pip download / wheel extraction)
set -euo pipefail

SITE="${1:?usage: assemble-extra.sh <site-dir> [matplotlib-build-dir] [python]}"
MPL="${2:-${WASI_BUILD:-/tmp/wasi-build}/matplotlib-build}"
PY="${3:-python3}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "$SITE"

# --- lxml (C extension built by the matplotlib pipeline's 05-lxml.sh) ---
if [ ! -f "$MPL/lxml-ext/etree.so" ]; then
    echo ">>> [assemble-extra] building lxml..."
    bash "$REPO/build/matplotlib-pipeline/05-lxml.sh"
else
    echo ">>> [assemble-extra] lxml already built"
fi
if [ ! -f "$SITE/lxml/etree.so" ]; then
    echo ">>> [assemble-extra] assembling lxml..."
    cp -r "$MPL/lxml-6.0.0/src/lxml" "$SITE/lxml"
    find "$SITE/lxml" \( -name "*.pyx" -o -name "*.pxd" -o -name "*.pxi" -o -name "*.c" \) -delete 2>/dev/null || true
    cp "$MPL/lxml-ext/"*.so "$SITE/lxml/"
fi

# --- bs4 (pure wheels: beautifulsoup4 + soupsieve) ---
if [ ! -d "$SITE/bs4" ]; then
    echo ">>> [assemble-extra] bs4..."
    mkdir -p "$MPL/bs4-dl"
    $PY -m pip download beautifulsoup4 soupsieve --only-binary :all: --no-deps -d "$MPL/bs4-dl" 2>/dev/null
    for w in "$MPL/bs4-dl"/*.whl; do $PY -c "import zipfile; zipfile.ZipFile('$w').extractall('$SITE')"; done
else
    echo ">>> [assemble-extra] bs4 already present"
fi

# --- extras set (sympy, ruamel.yaml, simplejson, regex, audioop-lts, pyyaml, orjson, tiktoken, skimage, opencv) ---
echo ">>> [assemble-extra] extras: sympy, ruamel.yaml, simplejson, regex, audioop-lts, pyyaml, orjson, tiktoken, skimage, opencv..."
for s in 01-pure-wheels 02-regex 03-audioop 04-pyyaml 05-orjson 06-tiktoken 07-skimage 08-opencv; do
    SITE="$SITE" bash "$REPO/build/extras/$s.sh"
done

# --- strip host-platform extensions (pure-wheel drift: fonttools qu2cu) ---
bash "$REPO/build/strip-host-extensions.sh" "$SITE"

echo ">>> [assemble-extra] done: $SITE"
