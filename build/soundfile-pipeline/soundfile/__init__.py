"""soundfile-compatible pure-Python shim over ``_soundfile_native``.

Path B of the soundfile worklog (design_docs/code_interpreter_wasm_soundfile_build.md):
the literal soundfile package needs cffi + ctypes + dlopen, none of which exist in
the wasm32-wasip2 sandbox. This module reproduces the public API of soundfile 0.14.0
(SoundFile, sf.read, sf.write, sf.info, exceptions, format tables) over a small
late-linked C extension wrapping libsndfile.

Supported: WAV/AIFF/AU/RAW (+ WAVEX etc. that libsndfile's internal codecs cover),
subtypes PCM_S8/16/24/32, PCM_U8, FLOAT, DOUBLE, ULAW, ALAW. FLAC/OGG require the
external-codec build (v2) and raise a clear error.
"""
from __future__ import annotations

import io
import os
import warnings

import numpy as np

from . import _soundfile_native as _native

__version__ = "0.14.0"

# ---------------------------------------------------------------------------
# Format / subtype / endian tables (values from soundfile 0.14.0, which mirror
# libsndfile's sndfile.h enum; stable data).
# ---------------------------------------------------------------------------
_formats = {'WAV': 65536, 'AIFF': 131072, 'AU': 196608, 'RAW': 262144, 'PAF': 327680,
            'SVX': 393216, 'NIST': 458752, 'VOC': 524288, 'IRCAM': 655360, 'W64': 720896,
            'MAT4': 786432, 'MAT5': 851968, 'PVF': 917504, 'XI': 983040, 'HTK': 1048576,
            'SDS': 1114112, 'AVR': 1179648, 'WAVEX': 1245184, 'SD2': 1310720, 'FLAC': 1638400,
            'CAF': 1703936, 'WVE': 1769472, 'OGG': 1835008, 'MPC2K': 1900544, 'RF64': 1966080}
_subtypes = {'PCM_S8': 1, 'PCM_16': 2, 'PCM_24': 3, 'PCM_32': 4, 'PCM_U8': 5, 'FLOAT': 6,
             'DOUBLE': 7, 'ULAW': 16, 'ALAW': 17, 'IMA_ADPCM': 18, 'MS_ADPCM': 19,
             'GSM610': 32, 'VOX_ADPCM': 33, 'G721_32': 48, 'G723_24': 49, 'G723_40': 50,
             'DWVW_12': 64, 'DWVW_16': 65, 'DWVW_24': 66, 'DWVW_N': 67, 'DPCM_8': 80,
             'DPCM_16': 81, 'VORBIS': 96, 'OPUS': 112, 'ALAC_16': 128, 'ALAC_20': 129,
             'ALAC_24': 130, 'ALAC_32': 131}
_endians = {'FILE': 0, 'LITTLE': 268435456, 'BIG': 536870912, 'CPU': 805306368}

# Default subtype per format when none is given (mirrors soundfile's
# _default_subtype table for the internal-codec formats).
_DEFAULT_SUBTYPE = {
    'WAV': 'PCM_16', 'AIFF': 'PCM_16', 'AU': 'PCM_16', 'RAW': 'PCM_16',
    'W64': 'PCM_16', 'WAVEX': 'PCM_16', 'RF64': 'PCM_16',
}

# Subtype -> (name, extension) display data (mirrors libsndfile's own strings).
_SUBTYPE_NAMES = {
    'PCM_S8': ('Signed 8 bit PCM', ''),
    'PCM_16': ('Signed 16 bit PCM', ''),
    'PCM_24': ('Signed 24 bit PCM', ''),
    'PCM_32': ('Signed 32 bit PCM', ''),
    'PCM_U8': ('Unsigned 8 bit PCM', ''),
    'FLOAT': ('32 bit float', ''),
    'DOUBLE': ('64 bit float', ''),
    'ULAW': ('U-Law', ''),
    'ALAW': ('A-Law', ''),
}
_FORMAT_NAMES = {
    'WAV': ('WAV (Microsoft)', 'wav'),
    'AIFF': ('AIFF (Apple/SGI)', 'aiff'),
    'AU': ('AU (Sun/NeXT)', 'au'),
    'RAW': ('RAW (header-less)', 'raw'),
    'W64': ('W64 (SoundFoundry)', 'w64'),
    'WAVEX': ('WAVEX (Microsoft)', 'wav'),
    'RF64': ('RF64 (RIFF 64)', 'wav'),
}

SEEK_SET, SEEK_CUR, SEEK_END = 0, 1, 2

# Native read codes (mirrors _soundfile_native.read dtype codes)
_DTYPE_NATIVE = {
    'int16': 0, 'int32': 1, 'float32': 2, 'float64': 3,
}
_DTYPE_NP = {
    'int16': np.int16, 'int32': np.int32, 'float32': np.float32, 'float64': np.float64,
}
# commands (sndfile.h)
SFC_SET_SCALE_FLOAT_INT_READ = 4116
SFC_SET_SCALE_INT_FLOAT_WRITE = 4117


class Error(Exception):
    pass


class LibsndfileError(Error):
    pass


class LibsndfileVersionError(LibsndfileError):
    pass


class SoundFileRuntimeError(Error):
    pass


class SoundFileWarning(UserWarning):
    pass


class FormatInfo:
    def __init__(self, name, extension):
        self.name = name
        self.extension = extension

    def __repr__(self):
        return f"FormatInfo(name={self.name!r}, extension={self.extension!r})"


class Info:
    def __init__(self, frames, samplerate, channels, format, subtype, sections, seekable,
                 format_info, subtype_info):
        self.frames = frames
        self.samplerate = samplerate
        self.channels = channels
        self.format = format
        self.subtype = subtype
        self.sections = sections
        self.seekable = seekable
        self.format_info = format_info
        self.subtype_info = subtype_info

    def __repr__(self):
        return (f"Info(frames={self.frames}, samplerate={self.samplerate}, "
                f"channels={self.channels}, format={self.format}, "
                f"subtype={self.subtype}, sections={self.sections}, "
                f"seekable={self.seekable})")


def _lookup(value, table, names):
    for key, val in table.items():
        if val == value:
            return FormatInfo(*names.get(key, (key, '')))
    return FormatInfo(f'0x{value:x}', '')


def _format_name(fmt):
    return _lookup(fmt & 0xFFFF0000, _formats, _FORMAT_NAMES)


def _subtype_name(fmt):
    return _lookup(fmt & 0xFFFF, _subtypes, _SUBTYPE_NAMES)


def _parse_args(file, mode='r', samplerate=None, channels=None, subtype=None,
                format=None, endian=None):
    """Resolve (fileobj_or_path, sfm_mode, fmt_int) like soundfile does."""
    if mode not in ('r', 'r+', 'w', 'w+'):
        raise ValueError(f'unknown mode: {mode!r} (must be one of "r", "r+", "w", "w+")')
    fmt = 0
    if mode != 'r':
        if format is None:
            raise TypeError("'format' is required for write modes")
        if isinstance(format, str):
            try:
                fmt |= _formats[format]
            except KeyError:
                raise ValueError(f'unsupported format: {format!r}')
        else:
            fmt |= int(format)
        if subtype is not None:
            if isinstance(subtype, str):
                try:
                    fmt |= _subtypes[subtype]
                except KeyError:
                    raise ValueError(f'unsupported subtype: {subtype!r}')
            else:
                fmt |= int(subtype)
        else:
            # soundfile defaults the subtype per format (e.g. WAV -> PCM_16)
            if isinstance(format, str):
                default = _DEFAULT_SUBTYPE.get(format)
            elif isinstance(format, int):
                default = None
                for _k, _v in _formats.items():
                    if _v == (format & 0xFFFF0000):
                        default = _DEFAULT_SUBTYPE.get(_k)
                        break
            if default is not None:
                fmt |= _subtypes[default]
        if endian is not None:
            fmt |= _endians[endian]
        if samplerate is None or channels is None:
            raise TypeError("'samplerate' and 'channels' are required for write modes")
    return file, mode, fmt


class SoundFile:
    def __init__(self, file, mode='r', samplerate=None, channels=None, subtype=None,
                 format=None, endian=None, frames=None, always_2d=False, verbose=False,
                 _dtype=None, _data=None):
        file, mode, fmt = _parse_args(file, mode, samplerate, channels, subtype, format, endian)
        self._mode = mode
        self._name = getattr(file, 'name', None)
        self._closed = False
        self._sections = 0
        self._frames = frames if frames is not None else 0

        fileobj = None
        if hasattr(file, 'read') and hasattr(file, 'seek'):
            fileobj = file
        if mode != 'r':
            sr = int(samplerate)
            ch = int(channels)
            if fileobj is not None:
                self._h = _native.open_virtual(fileobj, mode, sr, ch, fmt)
            else:
                self._h = _native.open(file, mode, sr, ch, fmt)
        else:
            if fileobj is not None:
                self._h = _native.open_virtual(fileobj, mode)
            else:
                self._h = _native.open(file, mode)
            # int-scale commands, matching soundfile's behavior
            self._command(SFC_SET_SCALE_FLOAT_INT_READ, 1)
            self._command(SFC_SET_SCALE_INT_FLOAT_WRITE, 1)

        info = self._h.info()
        self._samplerate = info['samplerate']
        self._channels = info['channels']
        self._format = info['format']
        self._sections = info['sections']
        self._seekable = bool(info['seekable'])
        self._frames = info['frames']
        if self._frames is None:
            self._frames = 0

    # -- properties --------------------------------------------------------
    @property
    def samplerate(self):
        return self._samplerate

    @property
    def channels(self):
        return self._channels

    @property
    def frames(self):
        return self._frames

    @property
    def format(self):
        return self._format

    @property
    def subtype(self):
        return self._format & 0xFFFF

    @property
    def sections(self):
        return self._sections

    @property
    def seekable(self):
        return self._seekable

    @property
    def format_info(self):
        return _format_name(self._format)

    @property
    def subtype_info(self):
        return _subtype_name(self._format)

    @property
    def endian(self):
        return self._format & 0xF0000000

    @property
    def closed(self):
        return self._closed

    # -- low-level ---------------------------------------------------------
    def _command(self, cmd, value=0):
        self._h.command(cmd, int(value))

    def _check_not_closed(self):
        if self._closed:
            raise ValueError('I/O operation on closed file')

    # -- public API --------------------------------------------------------
    def close(self):
        if not self._closed:
            self._h.close()
            self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def seek(self, frames, whence=SEEK_SET):
        self._check_not_closed()
        return self._h.seek(int(frames), int(whence))

    def tell(self):
        self._check_not_closed()
        return self._h.seek(0, SEEK_CUR)

    def read(self, frames=-1, dtype='float64', always_2d=False, fill_value=None,
             out=None, *, channels=None):
        self._check_not_closed()
        if self._mode == 'w':
            raise RuntimeError('cannot read from a file opened for writing')
        if dtype not in _DTYPE_NATIVE:
            raise ValueError(f'unsupported dtype: {dtype!r} (use one of {sorted(_DTYPE_NATIVE)})')
        n = int(frames)
        if n < 0:
            n = self._frames - self.tell()
            if n < 0:
                n = 0
        n = min(n, self._frames - self.tell()) if self._frames is not None and n >= 0 else n
        if n < 0:
            n = 0
        raw = self._h.read(_DTYPE_NATIVE[dtype], n)
        data = np.frombuffer(raw, dtype=_DTYPE_NP[dtype])
        if channels is not None and channels != self._channels:
            raise ValueError('channels argument must match the file')
        if self._channels > 1 or always_2d:
            data = data.reshape(-1, self._channels)
        if fill_value is not None and n > 0 and len(data) < n * self._channels:
            pad = np.full((n * self._channels - len(data),), fill_value, dtype=data.dtype)
            data = np.concatenate([data, pad]).reshape(-1, self._channels) if (self._channels > 1 or always_2d) else np.concatenate([data, pad])
        if out is not None:
            out[...] = data
            return out
        return data

    def write(self, data, dtype=None):
        self._check_not_closed()
        if self._mode == 'r':
            raise RuntimeError('cannot write to a file opened for reading')
        arr = np.asarray(data)
        if arr.ndim == 1:
            arr = arr.reshape(-1, self._channels) if self._channels > 1 else arr
        elif arr.ndim == 2 and arr.shape[1] != self._channels:
            raise ValueError('data has wrong channel count')
        if dtype is None:
            dtype = str(arr.dtype)
        if dtype not in _DTYPE_NATIVE:
            raise ValueError(f'unsupported dtype: {dtype!r}')
        arr = arr.astype(_DTYPE_NP[dtype], copy=False)
        raw = arr.tobytes(order='C')
        written = self._h.write(raw, _DTYPE_NATIVE[dtype])
        return int(written)

    def blocks(self, frames=-1, overlap=0, dtype='float64', always_2d=False,
               fill_value=None, out=None, *, channels=None):
        self._check_not_closed()
        if frames < 0:
            frames = self._frames
        frames = int(frames)
        overlap = int(overlap)
        while True:
            if self.tell() >= self._frames:
                break
            block = self.read(frames=frames, dtype=dtype, always_2d=always_2d,
                              fill_value=fill_value, out=out, channels=channels)
            if len(block) == 0:
                break
            yield block
            if overlap > 0:
                self.seek(-overlap, SEEK_CUR)


# ---------------------------------------------------------------------------
# module-level convenience functions (soundfile API)
# ---------------------------------------------------------------------------

def available_subtypes(format=None):
    fmt = 0
    if format is not None:
        if isinstance(format, str):
            fmt = _formats[format]
        else:
            fmt = int(format)
    return {name: val for name, val in _subtypes.items() if _subtype_supported(fmt, val)}


def _subtype_supported(fmt, subtype):
    # libsndfile's internal (no external libs) build supports these subtypes for
    # the common container formats; FLAC/OGG families need the v2 external build.
    if fmt in (0, _formats['WAV'], _formats['AIFF'], _formats['AU'], _formats['RAW'],
               _formats['WAVEX'], _formats['W64'], _formats['RF64']):
        return subtype in (1, 2, 3, 4, 5, 6, 7, 16, 17)
    return False


def available_formats():
    supported = {k: v for k, v in _formats.items()
                 if k not in ('FLAC', 'OGG', 'CAF', 'WVE', 'MPC2K', 'SD2', 'VOC')}
    return supported


def check_format(format, subtype=None, endian=None):
    fmt = 0
    if isinstance(format, str):
        fmt |= _formats.get(format, 0)
    else:
        fmt |= int(format)
    if subtype is not None:
        fmt |= _subtypes.get(subtype, 0) if isinstance(subtype, str) else int(subtype)
    if endian is not None:
        fmt |= _endians.get(endian, 0) if isinstance(endian, str) else int(endian)
    return fmt != 0 and _format_supported(fmt)


def _format_supported(fmt):
    fmt_major = fmt & 0xFFFF0000
    return fmt_major in (0, _formats['WAV'], _formats['AIFF'], _formats['AU'],
                         _formats['RAW'], _formats['WAVEX'], _formats['W64'], _formats['RF64'])


def read(file, dtype='float64', always_2d=False, frames=-1, start=0, stop=None,
         fill_value=None, out=None, *, channels=None):
    with SoundFile(file, 'r') as f:
        if start != 0:
            f.seek(start)
        n = frames
        if stop is not None:
            n = stop - start
        data = f.read(frames=n, dtype=dtype, always_2d=always_2d,
                      fill_value=fill_value, out=out, channels=channels)
        sr = f.samplerate
    return data, sr


def write(file, data, samplerate, subtype=None, format=None, endian=None, closefd=True):
    arr = np.asarray(data)
    if format is None:
        if subtype is not None and isinstance(subtype, str) and 'PCM' in subtype:
            format = 'WAV'
        else:
            format = 'WAV'
    if format == 'FLAC' or format == 'OGG':
        raise SoundFileRuntimeError(
            f'format {format!r} requires the external-codec libsndfile build (v2); '
            'use WAV/AIFF/AU/RAW')
    with SoundFile(file, 'w', samplerate=samplerate, channels=arr.shape[1] if arr.ndim > 1 else 1,
                   subtype=subtype, format=format, endian=endian) as f:
        f.write(arr)


def info(file, verbose=False):
    with SoundFile(file, 'r') as f:
        return Info(f.frames, f.samplerate, f.channels, f.format, f.subtype,
                    f.sections, f.seekable, f.format_info, f.subtype_info)


def LibsndfileVersionErrorCheck():
    # Keep the import surface compatible: the real soundfile raises this if the
    # bundled libsndfile is too old; our native binding is always current.
    return None
