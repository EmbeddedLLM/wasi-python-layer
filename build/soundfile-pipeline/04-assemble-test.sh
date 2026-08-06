#!/bin/bash
# Stage 4: assemble soundfile into the shared mpl-site (site-packages root)
# and verify in eryx with a scratch factory.
#
# The matplotlib-pipeline's 04-assemble-test.sh builds $SITE (mpl-site);
# this stage adds soundfile/ + the native extension into the same tree so the
# site-packages tarball picks them up.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WASI_BUILD="${WASI_BUILD:-/tmp/wasi-build}"
SF_BUILD="$WASI_BUILD/libsndfile-build"
SITE="${SITE:-$WASI_BUILD/matplotlib-build/mpl-site}"

echo ">>> Assembling soundfile into $SITE ..."
mkdir -p "$SITE/soundfile"
cp -r "$HERE/soundfile/." "$SITE/soundfile/"
cp "$SF_BUILD/ext/_soundfile_native.cpython-314-wasm32-wasi.so" "$SITE/soundfile/"

echo ">>> Verifying in eryx (scratch factory, imports=['soundfile'])..."
if [ -z "${ERYX_PY:-}" ]; then
    echo ">>> Skipping eryx verification (set ERYX_PY=/path/to/venv/python to run it; CI gates on the factory link + runtime smoke)"
    exit 0
fi
"$ERYX_PY" - "$SITE" <<'EOF'
import sys, time, eryx
t0 = time.time()
f = eryx.SandboxFactory(site_packages=sys.argv[1], imports=["soundfile"])
print(f"factory build: {time.time()-t0:.1f}s")
sb = f.create_sandbox()
code = """
import io, soundfile as sf, numpy as np
buf = io.BytesIO()
d = np.arange(44100, dtype='float32') / 44100
sf.write(buf, d, 44100, subtype='FLOAT')
buf.seek(0)
d2, sr = sf.read(buf)
print('RT', sr, np.allclose(d, d2, atol=1e-7), d2.shape)
buf.seek(0)
i = sf.info(buf)
print('INFO', hex(i.format), hex(i.subtype), i.frames)
"""
r = sb.execute(code)
print("stdout:", r.stdout)
assert "RT 44100 True" in r.stdout, f"acceptance failed: {r.stderr}"
print(">>> soundfile acceptance PASSED")
EOF
