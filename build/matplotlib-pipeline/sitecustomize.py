"""WASM sandbox startup: fix encodings + set MPLCONFIGDIR.

eryx bundled CPython stdlib lacks some encodings (utf-16-be, etc.)
that matplotlib font manager needs. The codec registry is frozen
during wizer pre-initialization, so we extend encodings.__path__
here to include our site-packages encodings directory.

MPLCONFIGDIR: during wizer pre-init, /tmp is not mounted (no volumes).
We fall back to /site-packages/.mpl-config which exists in the snapshot.
At runtime, /tmp is mounted and sitecustomize re-runs, preferring /tmp.
"""
import os

# matplotlib font cache: prefer /tmp (runtime), fall back to /site-packages (wizer pre-init)
for _mpl_dir in ("/tmp/mpl-config", "/site-packages/.mpl-config"):
    try:
        os.makedirs(_mpl_dir, exist_ok=True)
        os.environ["MPLCONFIGDIR"] = _mpl_dir
        break
    except OSError:
        continue

# Extend encodings search path for missing codecs
import encodings

_site_enc = os.path.join(os.path.dirname(__file__), "encodings")
if os.path.isdir(_site_enc) and _site_enc not in encodings.__path__:
    encodings.__path__.append(_site_enc)

for _codec in ("utf_16_be", "utf_16_le", "utf_32_be", "utf_32_le", "latin_1"):
    try:
        __import__("encodings." + _codec)
    except ImportError:
        pass

