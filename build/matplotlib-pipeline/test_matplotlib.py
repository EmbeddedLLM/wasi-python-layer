#!/usr/bin/env python3
"""Verify matplotlib 3.11.1 in eryx: import + 5 plot types → PNG.

Usage: test_matplotlib.py [site-packages-dir]
"""
import sys
import tempfile

import eryx

SITE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wasi-build/matplotlib-build/mpl-site"

TESTS = {
    "import": '''
import os; os.environ["MPLCONFIGDIR"]="/tmp/m"; os.makedirs("/tmp/m",exist_ok=True)
import matplotlib; matplotlib.use("Agg")
print("MPL_OK", matplotlib.__version__)
''',
    "line_plot": '''
import os; os.environ["MPLCONFIGDIR"]="/tmp/m"; os.makedirs("/tmp/m",exist_ok=True)
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, io
fig, ax = plt.subplots()
ax.plot([1,2,3,4], [1,4,9,16], label="y=x^2")
ax.set_xlabel("x"); ax.set_ylabel("y"); ax.set_title("Line"); ax.legend()
buf = io.BytesIO(); fig.savefig(buf, format="png"); plt.close(fig)
print("LINE_PNG", len(buf.getvalue()))
''',
    "scatter_numpy": '''
import os; os.environ["MPLCONFIGDIR"]="/tmp/m"; os.makedirs("/tmp/m",exist_ok=True)
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, numpy as np, io
np.random.seed(42); x, y = np.random.randn(2, 100)
fig, ax = plt.subplots(); ax.scatter(x, y, c=x+y, cmap="viridis", alpha=0.7)
buf = io.BytesIO(); fig.savefig(buf, format="png"); plt.close(fig)
print("SCATTER_PNG", len(buf.getvalue()))
''',
    "histogram": '''
import os; os.environ["MPLCONFIGDIR"]="/tmp/m"; os.makedirs("/tmp/m",exist_ok=True)
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, numpy as np, io
fig, ax = plt.subplots(); ax.hist(np.random.randn(1000), bins=30, edgecolor="black")
buf = io.BytesIO(); fig.savefig(buf, format="png"); plt.close(fig)
print("HIST_PNG", len(buf.getvalue()))
''',
    "contour": '''
import os; os.environ["MPLCONFIGDIR"]="/tmp/m"; os.makedirs("/tmp/m",exist_ok=True)
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, numpy as np, io
x = np.linspace(-3,3,50); X, Y = np.meshgrid(x, x)
Z = np.sin(X) * np.cos(Y)
fig, ax = plt.subplots(); cs = ax.contourf(X, Y, Z, levels=20, cmap="RdBu")
fig.colorbar(cs)
buf = io.BytesIO(); fig.savefig(buf, format="png"); plt.close(fig)
print("CONTOUR_PNG", len(buf.getvalue()))
''',
}


def main():
    tmpdir = tempfile.mkdtemp(prefix="mpl-test-")
    sb = eryx.SandboxFactory(site_packages=SITE).create_sandbox(
        volumes=[(tmpdir, "/tmp", False)])

    passed = 0
    for name, code in TESTS.items():
        try:
            res = sb.execute(code)
            out = res.stdout.strip() if res.stdout else ""
            if res.stderr and ("Traceback" in res.stderr or "Error" in res.stderr):
                lines = [l for l in res.stderr.split('\n')
                         if l.strip() and 'cache' not in l and 'Axes3D' not in l]
                print(f"[{name}] FAIL: {lines[-1] if lines else 'unknown'}")
            else:
                print(f"[{name}] {out}")
                passed += 1
        except Exception as e:
            print(f"[{name}] FAIL: {str(e).strip().split(chr(10))[-1]}")

    if passed == len(TESTS):
        print("ALL_MATPLOTLIB_TESTS_OK")
    else:
        print(f"WARN: {passed}/{len(TESTS)} passed")
        sys.exit(1)


if __name__ == "__main__":
    main()
