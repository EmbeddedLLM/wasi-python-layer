#!/bin/bash
# Stage 1: download all source tarballs.
set -euo pipefail
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
MPL_BUILD="$WASI_BUILD/matplotlib-build"
mkdir -p "$MPL_BUILD"
cd "$MPL_BUILD"

download() {
    local url="$1" file="$2"
    if [ -f "$file" ]; then echo "  [skip] $file exists"; return; fi
    echo "  [download] $file"
    curl -sL "$url" -o "$file"
}

echo ">>> Downloading sources..."
download "https://files.pythonhosted.org/packages/source/m/matplotlib/matplotlib-3.11.1.tar.gz" \
         "matplotlib-3.11.1.tar.gz"
download "https://download.savannah.nongnu.org/releases/freetype/freetype-2.14.3.tar.xz" \
         "freetype-2.14.3.tar.xz"
download "https://github.com/qhull/qhull/archive/v8.0.2/qhull-8.0.2.tar.gz" \
         "qhull-8.0.2.tar.gz"
download "https://files.pythonhosted.org/packages/source/c/contourpy/contourpy-1.3.2.tar.gz" \
         "contourpy-1.3.2.tar.gz"
download "https://files.pythonhosted.org/packages/source/k/kiwisolver/kiwisolver-1.4.8.tar.gz" \
         "kiwisolver-1.4.8.tar.gz"

# Extract
for archive in *.tar.gz *.tar.xz; do
    [ -f "$archive" ] || continue
    dir="${archive%.tar.*}"
    # Handle versioned directory names
    case "$archive" in
        qhull-8.0.2.tar.gz) dir="qhull-8.0.2" ;;
    esac
    if [ -d "$dir" ]; then echo "  [skip] $dir/ extracted"; continue; fi
    echo "  [extract] $archive"
    tar xf "$archive"
done

# matplotlib sdist has a nested directory
if [ -d "matplotlib/matplotlib-3.11.1" ] && [ ! -d "matplotlib-3.11.1" ]; then
    mv matplotlib/matplotlib-3.11.1 .
fi

# Install build tools into build-venv
VENV="$WASI_BUILD/build-venv"
if [ -x "$VENV/bin/pip" ]; then
    "$VENV/bin/pip" install -q pybind11 cppy cmake ninja 2>/dev/null || true
fi

echo ">>> Sources ready."
