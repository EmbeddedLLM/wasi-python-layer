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

# matplotlib font cache: prefer /tmp (runtime), fall back to /site-packages (wizer pre-init).
# Set MPLCONFIGDIR UNCONDITIONALLY — matplotlib needs the variable; makedirs on the
# read-only /site-packages mount only succeeds when .mpl-config already exists, so a
# "set only on success" loop leaves it unset on fresh builds (cold-build regression,
# 2026-08-06: gate failed with 'Matplotlib requires access to a writable cache dir').
_mpl_dir = "/tmp/mpl-config"
try:
    os.makedirs(_mpl_dir, exist_ok=True)
except OSError:
    # Relative to this module, so it works under ANY site-packages mount prefix
    # (/site-packages for the factory/sandbox path, /site-packages-0 for the
    # PythonExecutor session path — v8-kopi plan §13.3).
    _mpl_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".mpl-config")
os.environ["MPLCONFIGDIR"] = _mpl_dir

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

# HEIC/HEIF: register the _wasi_heif PIL opener so Image.open() transparently
# decodes .heic/.heif (Pillow core has no HEIF support; the wasm layer ships
# wasi_heif — a libheif-based decode-only plugin, see build/pillow/_wasi_heif.c).
#
# WIZER PRE-INIT LIMITATION (Trap P12): ANY import of a dylink extension module
# during the snapshot phase traps with "indirect call type mismatch" at
# _PyImport_FindSharedFuncptr — the wizer pre-init context cannot resolve
# dynamic imports (verified 2026-08-10: import PIL._imaging / _wasi_heif at
# pre-init traps even for the OLD working .so files; import PIL (pure Python
# __init__) is fine). A wasm trap is NOT catchable by `except Exception`, so a
# naive `import wasi_heif` here killed the whole factory snapshot. sitecustomize
# re-runs at runtime with /tmp mounted, so defer extension imports to that run:
# the /tmp makedirs above fails ONLY during pre-init (no volumes) — reuse it.
try:
    os.makedirs("/tmp/mpl-config-deferred", exist_ok=True)
    # runtime run: extension imports are safe here
    import wasi_heif

    wasi_heif.register_heif_opener()
except OSError:
    pass  # pre-init snapshot: defer to the runtime sitecustomize run
except Exception:
    pass

