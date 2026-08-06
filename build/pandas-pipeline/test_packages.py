#!/usr/bin/env python3
"""Verify the wasm numpy 2.5.1 + pandas 3.0.3 site-packages in eryx.

Usage: test_packages.py <site-packages-dir>
Runs numpy ops + pandas Series + DataFrame operations and asserts they are correct.
"""
import sys
import tempfile

import eryx

SITE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wasi-build/combined-site"

NUMPY_CODE = r'''
import numpy as np
assert np.__version__.startswith("2.5"), np.__version__
a = np.array([[1.0, 2.0], [3.0, 4.0]])
assert float((a @ a).sum()) == 54.0
assert round(float(np.linalg.det(a)), 6) == -2.0
assert round(float(np.fft.fft(np.ones(4)).real.sum()), 6) == 4.0
assert int(np.einsum("ij,jk->ik", a, a).sum()) == 54
assert np.dtype(np.longdouble).itemsize == 16
print("NUMPY_OK", np.__version__)
'''

PANDAS_CODE = r'''
import pandas as pd
df = pd.DataFrame({"a": [1, 2, 3, 4], "b": [10.0, 20.0, 30.0, 40.0], "g": ["x", "y", "x", "y"]})
assert df.shape == (4, 3)
assert int(df["a"].sum()) == 10 and float(df["b"].sum()) == 100.0
assert float(df["a"].mean()) == 2.5
assert df.groupby("g")["a"].sum().to_dict() == {"x": 4, "y": 6}
assert df.sort_values("a", ascending=False)["a"].tolist() == [4, 3, 2, 1]
assert df[df["a"] > 2]["a"].tolist() == [3, 4]
assert df["a"].apply(lambda x: x * 2).tolist() == [2, 4, 6, 8]
assert int(df["a"].describe()["count"]) == 4
assert df["g"].value_counts().to_dict() == {"x": 2, "y": 2}
df.to_csv("/tmp/t.csv", index=False)
assert pd.read_csv("/tmp/t.csv")["a"].tolist() == [1, 2, 3, 4]
assert df.head(2)["a"].tolist() == [1, 2]
s = pd.Series([1, 2, 3])
assert int(s.sum()) == 6
print("PANDAS_OK", pd.__version__)
'''


def main():
    sb = eryx.SandboxFactory(site_packages=SITE).create_sandbox(
        volumes=[(tempfile.mkdtemp(prefix="wasm-test-"), "/tmp", False)])
    for name, code in [("numpy", NUMPY_CODE), ("pandas", PANDAS_CODE)]:
        res = sb.execute(code)
        if res.stderr and "Error" in res.stderr:
            print(f"[{name}] FAILED:\n{res.stderr[-2000:]}")
            sys.exit(1)
        print(f"[{name}] {res.stdout.strip()}")
    print("ALL_WASM_PACKAGES_OK")


if __name__ == "__main__":
    main()
