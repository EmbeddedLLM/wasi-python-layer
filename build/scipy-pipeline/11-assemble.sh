#!/bin/bash
# Stage 18 / M19: append SciPy into the assembled site-packages tree (mpl-site).
#
# HARD RULE (design doc Stage 18): NEVER recreate mpl-site. Append only —
# scipy behaves like soundfile/extras. Recreating the site silently drops
# previously assembled packages (numpy/pandas/matplotlib/PIL/soundfile/lxml/...).
#
# Usage:
#   bash 11-assemble.sh [site-dir]
#     site-dir  default: $WASI_BUILD/matplotlib-build/mpl-site
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${1:-$WASI_BUILD/matplotlib-build/mpl-site}"
SCIPY_INSTALL="$WASI_BUILD/scipy-build/install/usr/local/lib/python3.14/site-packages"

test -d "$SCIPY_INSTALL/scipy" || {
  echo "[assemble] scipy install missing — run 09-scipy-build.sh first" >&2
  exit 1
}
mkdir -p "$SITE"

if [ -d "$SITE/scipy" ]; then
  echo "[assemble] scipy already in $SITE (skip)"
else
  echo "[assemble] appending scipy -> $SITE"
  cp -a "$SCIPY_INSTALL/scipy" "$SITE/"
  # dist-info: meson installs it only when built with the standard metadata
  # path; the -D_without-fortran cross build may omit it. Consumers mount the
  # tree for import (no pip resolution), so absence is non-fatal — but copy it
  # when present.
  if ls "$SCIPY_INSTALL"/scipy-*.dist-info >/dev/null 2>&1; then
    cp -a "$SCIPY_INSTALL"/scipy-*.dist-info "$SITE/"
  else
    echo "[assemble] note: no scipy-*.dist-info in the install (not fatal for import consumers)"
  fi
fi

# ── assembly integrity gate (Stage 18): nothing previously supported vanished ──
for p in numpy pandas matplotlib PIL soundfile scipy; do
  if [ ! -d "$SITE/$p" ]; then
    echo "[assemble] FAIL: $SITE/$p missing — assembly broke the tree" >&2
    exit 1
  fi
done
echo "[assemble] OK: scipy present, no previously supported package disappeared"
