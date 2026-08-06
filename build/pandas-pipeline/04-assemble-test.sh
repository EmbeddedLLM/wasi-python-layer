#!/bin/bash
# Stage 4: assemble numpy 2.5.1 + pandas + pure-python deps + stubs into one site-packages,
# then verify in eryx (numpy ops + pandas Series + DataFrame).
#
# Env: WASI_BUILD (default /tmp/wasi-build). Produces: $WASI_BUILD/combined-site.
set -euo pipefail
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE="$WASI_BUILD/combined-site"
PD="$WASI_BUILD/pandas"
rm -rf "$SITE"
mkdir -p "$SITE"

# --- numpy 2.5.1 (from stage 2 install) ---
echo ">>> copying numpy 2.5.1"
cp -r "$WASI_BUILD/numpy251-install/usr/local/lib/python3.14/site-packages/numpy" "$SITE/"

# --- pandas (from stage 3) ---
echo ">>> copying pandas"
cp -r "$PD/pandas-wasi/pandas" "$SITE/"

# --- pure-python deps (dateutil, pytz, tzdata, six) ---
echo ">>> fetching pure-python deps"
DEPS="$WASI_BUILD/pydeps"; mkdir -p "$DEPS"
"$WASI_BUILD/build-venv/bin/pip" download --no-deps --only-binary :all: \
  python-dateutil pytz tzdata six -d "$DEPS" >/dev/null
for whl in "$DEPS"/*.whl; do
  python3 -c "import zipfile; zipfile.ZipFile('$whl').extractall('$SITE')"
done

# --- mmap stub (no mmap on wasm) ---
cp "$HERE/mmap.py" "$SITE/mmap.py"

echo "=== Stage 4: assembled site-packages at $SITE ==="
ls "$SITE"

# --- verify in eryx (needs pyeryx; use the eryx-probe venv if present) ---
ERYX_PY="${ERYX_PY:-/tmp/eryx-probe/bin/python}"
if [ -x "$ERYX_PY" ]; then
  echo ">>> verifying in eryx"
  "$ERYX_PY" "$HERE/test_packages.py" "$SITE"
else
  echo ">>> no eryx python at $ERYX_PY; set ERYX_PY to a venv with pyeryx to verify."
  echo "    e.g.: ERYX_PY=/path/to/venv/bin/python $0"
fi
