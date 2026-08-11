#!/usr/bin/env python3
"""Functional sweep for the wasm site-packages layer.

Beyond the import gate (verify-imports.py), runs a representative operation
for every shipped library inside the wasm guest and asserts a concrete result.
Usage:
    .venv/bin/python scripts/verify-functionality.py [site-packages-dir]
"""
from __future__ import annotations

import io
import os
import sys
from pathlib import Path

CHECKS = {
    "numpy": (
        "import numpy as np; a = np.arange(12).reshape(3, 4); "
        "assert a.sum() == 66 and a.itemsize == 4; print('OK')"  # wasm32 default int is 32-bit
    ),
    "pandas": (
        "import pandas as pd; df = pd.DataFrame({'a': [1, 2, 3], 'b': [4, 5, 6]}); "
        "assert df.groupby('a').b.mean().loc[2] == 5.0; print('OK')"
    ),
    "matplotlib": (
        "import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt; "
        "import io; fig, ax = plt.subplots(); ax.plot([1, 2, 3]); "
        "buf = io.BytesIO(); fig.savefig(buf, format='png'); "
        "assert buf.getvalue().startswith(b'\\x89PNG'); print('OK')"
    ),
    "contourpy": (
        "import contourpy; import numpy as np; "
        "c = contourpy.contour_generator(z=np.zeros((4, 4))); "
        "lines = c.lines(0.5); assert isinstance(lines, list); print('OK')"
    ),
    "PIL": (
        "from PIL import Image; import io; im = Image.new('RGB', (8, 8), 'red'); "
        "buf = io.BytesIO(); im.save(buf, format='PNG'); "
        "assert Image.open(io.BytesIO(buf.getvalue())).size == (8, 8); print('OK')"
    ),
    "soundfile": (
        "import soundfile as sf; import io, numpy as np; "
        "buf = io.BytesIO(); data = np.zeros((100, 1), dtype='int16'); "
        "sf.write(buf, data, 8000, format='WAV'); buf.seek(0); "
        "out, sr = sf.read(buf); assert sr == 8000 and out.shape == (100,); print('OK')"
    ),
    "lxml": (
        "from lxml import etree; root = etree.fromstring(b'<a><b>1</b></a>'); "
        "assert root.xpath('string(/a/b)') == '1'; print('OK')"
    ),
    "bs4": (
        "from bs4 import BeautifulSoup; s = BeautifulSoup('<p class=x>hi</p>', 'html.parser'); "
        "assert s.p['class'] == ['x'] and s.p.text == 'hi'; print('OK')"
    ),
    "regex": (
        "import regex; m = regex.match(r'\\d+', '123abc'); assert m.group() == '123'; print('OK')"
    ),
    "audioop": (
        "import audioop; import numpy as np; d = np.zeros(20, dtype='int16').tobytes(); "
        "r = audioop.mul(d, 2, 2.0); assert len(r) == 40; print('OK')"
    ),
    "orjson": (
        "import orjson; assert orjson.loads(orjson.dumps({'k': [1, 2]})) == {'k': [1, 2]}; print('OK')"
    ),
    "simplejson": (
        "import simplejson; assert simplejson.loads(simplejson.dumps([1, 'a'])) == [1, 'a']; print('OK')"
    ),
    "ruamel.yaml": (
        "import ruamel.yaml; y = ruamel.yaml.YAML(); "
        "assert y.load('a: 1') == {'a': 1}; print('OK')"
    ),
    "yaml": (
        "import yaml; assert yaml.safe_load('a: 1') == {'a': 1}; print('OK')"
    ),
    "tiktoken": (
        "import tiktoken; enc = tiktoken.encoding_for_model('gpt-4o'); "
        "ids = enc.encode('hello world'); assert enc.decode(ids) == 'hello world'; print('OK')"
    ),
    "sympy": (
        "import sympy as sp; x = sp.symbols('x'); "
        "assert sp.simplify((x + 1) ** 2 - x**2 - 2 * x) == 1; print('OK')"
    ),
    "scipy": (
        "import numpy as np; from scipy import linalg, ndimage, fft; "
        "from scipy import sparse; from scipy.sparse.linalg import spsolve; "
        "A = np.array([[3., 1.], [1., 2.]]); b = np.array([9., 8.]); "
        "xs = linalg.solve(A, b); assert np.allclose(xs, [2., 3.]); "
        "x = np.zeros((9, 9)); x[4, 4] = 1; y = ndimage.gaussian_filter(x, 1.0); "
        "assert y.shape == (9, 9) and y[4, 4] > y[0, 0]; "
        "yf = fft.fft(np.array([1., 2., 3., 4.])); assert len(yf) == 4; "
        "A2 = sparse.csr_matrix([[3., 1.], [1., 2.]]); "
        "x2 = spsolve(A2, b); assert np.allclose(x2, [2., 3.]); print('OK')"
    ),
    "skimage": (
        "import numpy as np; from skimage.color import rgb2gray; "
        "from skimage.filters import gaussian; from skimage import morphology; "
        "a = np.zeros((8, 8, 3), dtype='uint8'); "
        "g = rgb2gray(a); assert g.shape == (8, 8); "
        "b = gaussian(a[:, :, 0].astype(float), sigma=1.0); assert b.shape == (8, 8); "
        "assert morphology.disk(3).shape == (7, 7); print('OK')"
    ),
    "cv2": (
        "import cv2, numpy as np; m = np.zeros((4, 4, 3), dtype='uint8'); "
        "g = cv2.cvtColor(m, cv2.COLOR_RGB2GRAY); assert g.shape == (4, 4); print('OK')"
    ),
}

_EXEC_TIMEOUT_MS = 600_000


def main() -> None:
    site = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        os.environ.get("WASI_SITE_PACKAGES", "/tmp/wasi-build/matplotlib-build/mpl-site")
    )
    if not (site / "numpy").is_dir():
        raise SystemExit(f"site-packages not found: {site}")

    import eryx

    factory = eryx.SandboxFactory(site_packages=str(site), packages=[], imports=["numpy"])
    # Mirror the consumer's runtime: writable /tmp (tiktoken's cache dir and
    # other tempfile users need it; a bare sandbox has no /tmp) and the
    # site-packages tree mounted read-only at /site-packages (package data
    # files — fonts, .npy tables — are not part of the baked snapshot).
    sandbox = factory.create_sandbox(
        resource_limits=eryx.ResourceLimits(execution_timeout_ms=_EXEC_TIMEOUT_MS),
        volumes=[("/tmp", "/tmp", False), (str(site), "/site-packages", True)],
    )
    failed = 0
    for name, code in CHECKS.items():
        try:
            r = sandbox.execute(code)
            ok = "OK" in r.stdout
            detail = ""
        except Exception as exc:  # noqa: BLE001 — report + continue the sweep
            ok = False
            detail = (str(exc) or "execute raised").strip()[:400]
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            failed += 1
            if detail:
                print(f"      {detail}")
    print(f"\n{len(CHECKS) - failed}/{len(CHECKS)} functional checks passed")
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
