"""HEIC/HEIF support for the wasm sandbox via the ``_wasi_heif`` extension.

Pillow core has no HEIF codec in any version; this module registers a PIL
opener that decodes through libheif (decode-only). Importing the module
registers the opener immediately; ``register_heif_opener()`` is idempotent
and called defensively from sitecustomize.

Decode is primary-image only (the standard display semantics) and always
returns RGBA.
"""

from PIL import Image

from _wasi_heif import decode  # noqa: F401  (re-export for callers)

_ACCEPT_BRANDS = (
    b"heic",  # HEVC-in-HEIF
    b"heix",  # HEVC-in-HEIF (10-bit)
    b"hevc",  # HEVC image sequence
    b"hevx",  # HEVC image sequence (10-bit)
    b"mif1",  # generic image collection
    b"msf1",  # generic image sequence
    b"avif",  # AV1-in-HEIF
    b"avis",  # AV1 image sequence
)

_REGISTERED = False


def _accept(prefix: bytes) -> bool:
    # ISO-BMFF ftyp box: 4-byte size + b"ftyp" + 4-byte major brand.
    return (
        len(prefix) >= 12
        and prefix[4:8] == b"ftyp"
        and prefix[8:12] in _ACCEPT_BRANDS
    )


def _open(fp, filename=None):
    data = fp.read()
    width, height, stride, rgba = decode(data)
    return Image.frombuffer("RGBA", (width, height), rgba, "raw", "RGBA", stride, 1)


def register_heif_opener():
    global _REGISTERED
    if _REGISTERED:
        return
    Image.register_open("HEIF", _open, _accept)
    Image.register_extension("HEIF", ".heic")
    Image.register_extension("HEIF", ".heif")
    Image.register_mime("HEIF", "image/heic")
    _REGISTERED = True


register_heif_opener()
