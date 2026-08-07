#!/usr/bin/env python3
"""Guest import gate for the wasm site-packages layer.

Builds an eryx SandboxFactory from the assembled site-packages tree and
executes the import contract in a wasm guest, asserting every package
resolves. This is the artifact repo's own test: it proves the source track
produces a tree that actually executes in the wasm32-wasip2 runtime.

Used by source-gate.yml after scripts/wasm_setup.sh; also runnable by
developers against any assembled tree:

    WASI_SITE_PACKAGES=/path/to/site-packages .venv/bin/python scripts/verify-imports.py

Deliberately excluded (documented non-contract): networkx (bz2/_bz2 missing
on wasm) and imageio (skimage.io is out of scope; imageio ships in the tree
and imports from the mount, but is not gate-asserted).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

IMPORT_CODE = (
    "import numpy, pandas, matplotlib, matplotlib.pyplot\n"
    "import matplotlib.backends.backend_agg\n"
    "import contourpy, PIL, soundfile\n"
    "import lxml.etree, bs4, regex, audioop, orjson, simplejson\n"
    "import ruamel.yaml, yaml, tiktoken, tiktoken_ext.openai_public\n"
    "import sympy, skimage, cv2\n"
    "print('ALL IMPORTS OK')"
)

# The gate must build the factory the way consumers do — with the contract set
# pre-imported (consumers pre-import the same set into their factory). Pre-importing matplotlib at
# factory-build time populates its font cache into the site-packages tree
# (pre-init mount is writable; the runtime mount is read-only, so a fresh tree
# with no cache fails matplotlib import at runtime otherwise — cold-build
# regression caught 2026-08-06).
PRE_IMPORTS: tuple[str, ...] = (
    "numpy",
    "pandas",
    "matplotlib",
    "matplotlib.backends.backend_agg",
    "contourpy",
    "PIL",
    "soundfile",
    "lxml.etree",
    "bs4",
    "regex",
    "audioop",
    "orjson",
    "simplejson",
    "ruamel.yaml",
    "yaml",
    "tiktoken",
    "sympy",
    "skimage",
    "cv2",
)

# The cold import of numpy + matplotlib + cv2 + skimage in one execution takes
# well over the 5 s default execution timeout; raise it explicitly.
_EXEC_TIMEOUT_MS = 600_000


def main() -> None:
    wasi_build = Path(os.environ.get("WASI_BUILD", "/tmp/wasi-build"))
    site = Path(
        os.environ.get(
            "WASI_SITE_PACKAGES",
            wasi_build / "matplotlib-build" / "mpl-site",
        )
    )
    if not (site / "numpy").is_dir():
        raise SystemExit(
            f"assembled site-packages not found: {site}\n"
            "(run scripts/wasm_setup.sh first, or set WASI_SITE_PACKAGES)"
        )

    import eryx

    print(f"[verify] building factory (pre-importing {len(PRE_IMPORTS)} modules) from {site} ...")
    factory = eryx.SandboxFactory(
        site_packages=str(site), packages=[], imports=list(PRE_IMPORTS)
    )
    sandbox = factory.create_sandbox(
        resource_limits=eryx.ResourceLimits(execution_timeout_ms=_EXEC_TIMEOUT_MS)
    )
    result = sandbox.execute(IMPORT_CODE)
    if "ALL IMPORTS OK" not in result.stdout:
        print(f"import gate FAILED:\n{result.stderr}\n{result.stdout}")
        raise SystemExit(1)
    print("[verify] ok: all import-gate packages import in the guest")


if __name__ == "__main__":
    main()
