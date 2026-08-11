#!/usr/bin/env python3
"""P11 structural sweep: find PyMethodDef/PyGetSetDef handlers with the wrong
C arity (one-arg/zero-arg where CPython expects two). wasm32 call_indirect
type-checks arity, so these trap with "indirect call type mismatch" (see
design_docs/code_interpreter_wasm_webp_got_trap.md §10 and
code_interpreter_wasm_scipy_build.md Stage 0.1).

Usage: abi_sweep.py [files-or-dirs...]
Exit 0 when no 1-arg handlers are found; 1 otherwise.
"""
import re
import sys
from pathlib import Path

# Handler definition:  PyObject *name(params)   (params may span after ')'?)
DEF_RE = re.compile(r'^\s*([A-Za-z_][A-Za-z_0-9]*)\s*\(')


def top_level_params(sig: str) -> list[str]:
    depth = 0
    parts: list[str] = ['']
    for ch in sig:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append('')
        else:
            parts[-1] += ch
    return [p.strip() for p in parts if p.strip()]


def sweep_file(path: Path) -> list[tuple[int, str, str, str]]:
    lines = path.read_text(errors='replace').splitlines()
    hits: list[tuple[int, str, str, str]] = []
    for ln, line in enumerate(lines, 1):
        # PyMethodDef: {"name", (PyCFunction)fn, METH_*, ...}
        m = re.search(
            r'^\s*\{"([A-Za-z_][A-Za-z_0-9]*)",\s*(?:\(PyCFunction\))?'
            r'([A-Za-z_][A-Za-z_0-9]*)\s*,\s*METH_', line)
        # PyGetSetDef: {"name", (getter)fn, ...}
        g = re.search(
            r'^\s*\{"([A-Za-z_][A-Za-z_0-9]*)",\s*\([^)]*\)\s*'
            r'([A-Za-z_][A-Za-z_0-9]*)\s*,', line) if not m else None
        name, fn = (m.groups() if m else (g.groups() if g else (None, None)))
        if not fn:
            continue
        # locate the definition within 2500 lines above
        for j in range(ln - 2, max(0, ln - 2500), -1):
            dm = DEF_RE.match(lines[j])
            if dm and dm.group(1) == fn:
                params = top_level_params(lines[j].strip()[dm.end():])
                if len(params) < 2 and 'void' not in [p.lower() for p in params]:
                    hits.append((j + 1, name, fn, lines[j].strip()[:90]))
                break
    return hits


def main() -> int:
    targets = [Path(a) for a in sys.argv[1:]] or [Path('.')]
    files: list[Path] = []
    for t in targets:
        if t.is_dir():
            files += sorted(t.rglob('*.c')) + sorted(t.rglob('*.cpp')) \
                + sorted(t.rglob('*.cc'))
        else:
            files.append(t)
    bad = 0
    for f in files:
        for (ln, name, fn, sig) in sweep_file(f):
            bad += 1
            print(f"{f}:{ln}: 1-arg handler {name} -> {fn}: {sig}")
    if bad:
        print(f"[abi] {bad} incompatible CPython function-pointer signature(s) found")
        return 1
    print(f"[abi] {len(files)} file(s) swept: no 1-arg METH_NOARGS/getset handlers")
    return 0


if __name__ == '__main__':
    sys.exit(main())
