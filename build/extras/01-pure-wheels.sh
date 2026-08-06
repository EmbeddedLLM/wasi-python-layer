#!/bin/bash
# extras/01-pure-wheels.sh — pure-Python wheels into the extras site-packages.
#
# sympy + mpmath, ruamel.yaml, simplejson: all py3-none-any wheels, NO wasm
# compilation. Same pattern as the bs4 step (pip download --only-binary :all:
# --no-deps, unzip into the site tree; dist-info stripped).
#
# Usage:
#   SITE=/path/to/site-packages bash 01-pure-wheels.sh   # assemble into $SITE
#   (default SITE=$WASI_BUILD/extras-site)
#
# Pinned 2026-08-05 (PyPI JSON). Reproducibility: versions are exact; nothing
# is resolved at build time.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
PIP="$WASI_BUILD/build-venv/bin/pip"
DL="$WASI_BUILD/extras-dl"

SYMPY_VERSION="1.14.0"
MPMATH_VERSION="1.4.1"
RUAMEL_VERSION="0.19.1"
SIMPLEJSON_VERSION="4.1.1"

mkdir -p "$SITE" "$DL"

echo ">>> [extras/01] Cleaning stale wheels + package dirs (idempotent re-runs)..."
rm -f "$DL"/*.whl
rm -rf "$SITE/sympy" "$SITE/mpmath" "$SITE/ruamel" "$SITE/simplejson"

echo ">>> [extras/01] Downloading pure wheels (sympy $SYMPY_VERSION, mpmath $MPMATH_VERSION, ruamel.yaml $RUAMEL_VERSION, simplejson $SIMPLEJSON_VERSION)..."
"$PIP" download --no-deps --only-binary :all: \
    "sympy==$SYMPY_VERSION" "mpmath==$MPMATH_VERSION" \
    "ruamel.yaml==$RUAMEL_VERSION" \
    -d "$DL" >/dev/null
# simplejson: force the py3-none-any PURE wheel by URL — pip resolves the cp314
# manylinux wheel (host .so) when left to --only-binary :all: (2026-08-05 lesson).
SIMPLEJSON_URL="$(curl -s "https://pypi.org/pypi/simplejson/$SIMPLEJSON_VERSION/json" \
    | jq -r '.urls[] | select(.filename | endswith("py3-none-any.whl")) | .url' | head -1)"
[ -n "$SIMPLEJSON_URL" ] || { echo "ERROR: no py3-none-any wheel for simplejson $SIMPLEJSON_VERSION"; exit 1; }
curl -sL -o "$DL/simplejson-$SIMPLEJSON_VERSION-py3-none-any.whl" "$SIMPLEJSON_URL"

echo ">>> [extras/01] Extracting into $SITE..."
for whl in "$DL"/*.whl; do
    case "$(basename "$whl")" in
        sympy-*|mpmath-*|ruamel.yaml-*|ruamel_yaml-*|simplejson-*)
            unzip -qo "$whl" -d "$SITE" ;;
    esac
done
rm -rf "$SITE"/*.dist-info "$SITE"/*.data

# sympy 1.14.0 hard-imports ctypes at module load (`external/gmpy.py`, gmpy2
# detection); the wasm stdlib has no `_ctypes` → guard the import. LONG_MAX
# falls back to wasm32's C long size (4); gmpy2/flint never load on wasm, so
# this only affects startup. Verified 2026-08-05 (Checkpoint 1 lesson).
echo ">>> [extras/01] Patching sympy ctypes guard..."
"$WASI_BUILD/build-venv/bin/python" - <<EOF
from pathlib import Path
p = Path("$SITE/sympy/external/gmpy.py")
src = p.read_text()
old = "from ctypes import c_long, sizeof\n"
new = ("try:\n"
       "    from ctypes import c_long, sizeof\n"
       "except ImportError:  # wasm: no _ctypes (extras build 2026-08-05)\n"
       "    c_long = None\n"
       "    sizeof = lambda c: 4  # wasm32 C long\n")
assert old in src, "sympy gmpy.py changed upstream; re-verify the ctypes patch"
p.write_text(src.replace(old, new))
print("  patched sympy/external/gmpy.py")
EOF

echo ">>> [extras/01] Installed:"
for p in sympy mpmath ruamel simplejson; do
    [ -d "$SITE/$p" ] && echo "  $SITE/$p"
done
