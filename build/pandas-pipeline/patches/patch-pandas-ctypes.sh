#!/bin/bash
# pandas imports `ctypes` at module load (pandas/errors/__init__.py and
# pandas/core/interchange/from_dataframe.py), but eryx's wasm CPython has no _ctypes
# (no libffi). pandas only *uses* ctypes for Windows-only WinError() and runtime
# interchange casts, so wrap the top-level `import ctypes` in try/except.
#
# Usage: patch-pandas-ctypes.sh <pandas-source-or-package-dir>
#   (run on the source tree before building, and/or on the assembled package)
set -euo pipefail
PD="${1:?usage: patch-pandas-ctypes.sh <pandas-dir>}"
python3 - "$PD" <<'PYEOF'
import sys
from pathlib import Path
pd = Path(sys.argv[1])
targets = [pd / "pandas/errors/__init__.py", pd / "pandas/core/interchange/from_dataframe.py"]
for f in targets:
    if not f.exists():
        print(f"skip (missing): {f}"); continue
    t = f.read_text()
    if "except ImportError:  # wasm" in t:
        print(f"already patched: {f}"); continue
    lines = t.split("\n")
    for i, ln in enumerate(lines):
        if ln.strip() == "import ctypes":
            ind = ln[:len(ln) - len(ln.lstrip())]
            lines[i] = (f"{ind}try:\n{ind}    import ctypes\n"
                        f"{ind}except ImportError:  # wasm: no _ctypes\n{ind}    ctypes = None")
            break
    f.write_text("\n".join(lines))
    print(f"patched: {f}")
PYEOF
