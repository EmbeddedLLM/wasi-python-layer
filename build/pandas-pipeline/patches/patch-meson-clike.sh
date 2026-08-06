#!/bin/bash
# Wall 8 fix: meson wraps multiple static libs in GNU-style -Wl,--start-group/--end-group
# (compilers/mixins/clike.py, for any GnuLikeDynamicLinkerMixin -- LLD qualifies). wasm-ld
# does not support these. Skip the grouping when the target cpu_family == 'wasm32'.
#
# IMPORTANT: after patching, delete meson's __pycache__/clike*.pyc (stale bytecode silently
# un-patches it) and re-run `meson setup --reconfigure` so build.ninja is regenerated.
#
# Usage: patch-meson-clike.sh <vendored-meson-dir>
#   e.g. patch-meson-clike.sh $NUMPY_SRC/vendored-meson/meson
set -euo pipefail
MESON="${1:?usage: patch-meson-clike.sh <vendored-meson-dir>}"
F="$MESON/mesonbuild/compilers/mixins/clike.py"
[ -f "$F" ] || { echo "ERROR: $F not found"; exit 1; }
python3 - "$F" <<'PYEOF'
import sys
f = sys.argv[1]
t = open(f).read()
old = """            # Only add groups if there are multiple libraries.
            if group_end > group_start >= 0:
                # Last occurrence of a library
                new.insert(group_end + 1, '-Wl,--end-group')
                new.insert(group_start, '-Wl,--start-group')"""
new = """            # Only add groups if there are multiple libraries.
            # wasm-ld does not support -Wl,--start-group/--end-group; skip for wasm targets.
            _target_cpu = self.compiler.environment.machines[self.compiler.for_machine].cpu_family
            if group_end > group_start >= 0 and _target_cpu != 'wasm32':
                # Last occurrence of a library
                new.insert(group_end + 1, '-Wl,--end-group')
                new.insert(group_start, '-Wl,--start-group')"""
if "_target_cpu != 'wasm32'" in t:
    print("already patched:", f)
elif t.count(old) == 1:
    open(f, "w").write(t.replace(old, new, 1))
    print("patched", f)
else:
    sys.exit("ERROR: pattern not found (meson version drift?) in " + f)
PYEOF
# Clear stale bytecode so the patch takes effect.
find "$MESON/mesonbuild/compilers" -name 'clike*.pyc' -delete 2>/dev/null || true
find "$MESON/mesonbuild/compilers/mixins/__pycache__" -name 'clike*' -delete 2>/dev/null || true
echo "cleared clike bytecode cache"
