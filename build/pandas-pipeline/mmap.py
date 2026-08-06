"""Minimal mmap stub for wasm32-wasi (no memory-mapped file support).

eryx's bundled CPython has no `mmap` module. pandas/io/common.py does `import mmap`
at module load (for read_csv(memory_map=True)). This stub provides the names pandas
references so the import succeeds; actual memory-mapped I/O raises NotImplementedError
(a feature limitation, not an import blocker).

Install as `mmap.py` in the wasm site-packages (it shadows the absent stdlib module).
"""
ACCESS_DEFAULT = 0
ACCESS_READ = 1
ACCESS_WRITE = 2
ACCESS_COPY = 3
PAGESIZE = 65536
ALLOCATIONGRANULARITY = 65536


class error(Exception):
    pass


class mmap:
    def __init__(self, *args, **kwargs):
        raise NotImplementedError("mmap is not supported on wasm32-wasi")

    def __getattr__(self, name):
        raise NotImplementedError("mmap is not supported on wasm32-wasi")
