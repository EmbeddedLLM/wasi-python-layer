#!/bin/bash
# extras/04-pyyaml.sh — PyYAML pure-Python fallback (no _yaml C ext for v1).
#
# PyYAML ships the pure implementation in lib/yaml/ (the yaml/ dir is the Cython
# sources). The pure Loader/Dumper/SafeLoader work without _yaml — the import in
# lib/yaml/__init__.py is guarded. Upgrade path: libyaml + _yaml.c via the lxml
# pattern (pyyaml 6.0.3, documented in the plan §7).
#
# Usage: SITE=/path/site-packages bash 04-pyyaml.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
PY_VERSION="6.0.3"
BUILD="$WASI_BUILD/pyyaml-build"

mkdir -p "$BUILD"

echo ">>> [extras/04] Fetching PyYAML $PY_VERSION sdist..."
PY_URL="$(curl -s "https://pypi.org/pypi/pyyaml/$PY_VERSION/json" \
    | jq -r '.urls[] | select(.filename | endswith(".tar.gz")) | .url' | sed -n '1p')"
[ -n "$PY_URL" ] || { echo "ERROR: pyyaml sdist not found"; exit 1; }
if [ ! -d "$BUILD/src" ]; then
    curl -sL -o "$BUILD/pyyaml-$PY_VERSION.tar.gz" "$PY_URL"
    tar -xf "$BUILD/pyyaml-$PY_VERSION.tar.gz" -C "$BUILD"
    # Top dir is lowercase `pyyaml-6.0.3` in this sdist (not PyYAML-*): derive it
    # from the filesystem after extraction (a `tar tzf | head -1` pipeline dies
    # under `set -o pipefail` on tar's SIGPIPE — 2026-08-05 lesson).
    SRC="$(basename "$(ls -d "$BUILD"/pyyaml-* | sed -n '1p')")"
    mkdir -p "$BUILD/src"
    cp -r "$BUILD/$SRC"/* "$BUILD/src/"
fi

echo ">>> [extras/04] Copying pure yaml package..."
rm -rf "$SITE/yaml"
cp -r "$BUILD/src/lib/yaml" "$SITE/yaml"
# No .so — pure fallback only (v1). Verify the guard: __init__ must not
# hard-require _yaml. NOTE: a bare `grep | head` pipeline exits non-zero on no
# match (the GOOD case) under set -o pipefail — check with if, not a pipeline.
if grep -q "from yaml._yaml" "$SITE/yaml/__init__.py"; then
    echo "ERROR: yaml/__init__.py hard-requires _yaml" >&2
    exit 1
fi

echo ">>> [extras/04] Installed $SITE/yaml ($(find "$SITE/yaml" -name '*.py' | wc -l) py files, no .so)"
