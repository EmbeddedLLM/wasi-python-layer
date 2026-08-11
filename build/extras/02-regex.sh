#!/bin/bash
# extras/02-regex.sh — regex (single-C extension), soundfile 03-extension pattern.
#
# The amalgamated src/_regex.c is self-contained (no external libs); compile with
# wasi clang, late-link shape (dylink) against the cross libpython3.14.so — exactly
# the _soundfile_native recipe.
#
# Usage: SITE=/path/site-packages bash 02-regex.sh   (default $WASI_BUILD/extras-site)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SITE="${SITE:-$WASI_BUILD/extras-site}"
WASI_SDK="$WASI_BUILD/wasi-sdk"
CROSS_PREFIX="$WASI_BUILD/cpython-wasi/install"
# regex pinned to 2024.9.11 (last release BEFORE the re_get_* internal-API usage).
# regex releases ≥2024.11 reference CPython 3.13+'s `re_get_*` symbols, which the
# wasm CPython 3.14 build does NOT export (verified: llvm-nm shows zero re_get_*
# in libpython3.14.so; factory link fails "unresolved symbol re_get_all_cases").
# Functionality for row-UDF use is unaffected. Worklog Checkpoint 4 lesson.
RX_VERSION="2024.9.11"
BUILD="$WASI_BUILD/regex-build"

mkdir -p "$BUILD" "$SITE/regex"

echo ">>> [extras/02] Fetching regex $RX_VERSION sdist..."
RX_URL="$(curl -s "https://pypi.org/pypi/regex/$RX_VERSION/json" \
    | jq -r '.urls[] | select(.filename | endswith(".tar.gz")) | .url' | sed -n '1p')"
[ -n "$RX_URL" ] || { echo "ERROR: regex sdist not found"; exit 1; }
if [ ! -d "$BUILD/regex-$RX_VERSION" ]; then
    curl -sL -o "$BUILD/regex-$RX_VERSION.tar.gz" "$RX_URL"
    tar -xf "$BUILD/regex-$RX_VERSION.tar.gz" -C "$BUILD"
fi

echo ">>> [extras/02] Copying regex package + compiling _regex..."
rm -rf "$SITE/regex"
mkdir -p "$SITE/regex"
# 2024.9.11 sdist layout: package source lives in regex_3/ (pre-3.13 naming);
# the wheel renames it to regex/. Relative imports (regex.regex, regex._regex_core)
# make the copy-as-is work. Modern sdists put it in regex/.
PKGDIR="$BUILD/regex-$RX_VERSION"
[ -d "$PKGDIR/regex_3" ] && PKGDIR="$PKGDIR/regex_3"
cp "$PKGDIR/"*.py "$SITE/regex/"
# _regex is ONE extension built from _regex.c + _regex_unicode.c together
# (setup.py: Extension('regex._regex', [...'_regex.c', '_regex_unicode.c'])).
"$WASI_SDK/bin/clang" \
    --target=wasm32-wasip2 \
    --sysroot="$WASI_SDK/share/wasi-sysroot" \
    -O2 -fPIC -fvisibility=hidden \
    -I"$CROSS_PREFIX/include/python3.14" \
    "$PKGDIR/_regex.c" "$PKGDIR/_regex_unicode.c" \
    -shared -fuse-ld=lld \
    -Wl,--unresolved-symbols=import-dynamic \
    "$CROSS_PREFIX/lib/libpython3.14.so" \
    -o "$SITE/regex/_regex.cpython-314-wasm32-wasi.so"

ls -la "$SITE/regex/" | sed -n "1,6p"
