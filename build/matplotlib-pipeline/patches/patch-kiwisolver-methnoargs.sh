#!/bin/bash
# Trap P11 (wasm ABI): METH_NOARGS handlers AND getset getters MUST take two
# args (PyObject *self, PyObject *unused / void *closure). wasm32 call_indirect
# type-checks arity, so 1-arg handlers compile to (i32)->i32 and trap
# ("indirect call type mismatch") when CPython dispatches them.
# kiwisolver 1.4.8:
#   - constraint.cpp: 4 METH_NOARGS methods (expression/op/strength/violated)
#   - strength.cpp:   4 getset getters (weak/medium/strong/required)
# Same class as Pillow's _webp.c/_imaging.c/_imagingft.c/encode.c (see
# vllm-responses design_docs/code_interpreter_wasm_webp_got_trap.md §9).
set -euo pipefail
KW_SRC="${1:?kiwisolver source dir}"

for name in Constraint_expression Constraint_op Constraint_strength Constraint_violated; do
  sed -i "s/^${name}(Constraint \\*self)\$/${name}(Constraint *self, PyObject *unused)/" "$KW_SRC/py/src/constraint.cpp"
done
for name in strength_weak strength_medium strength_strong strength_required; do
  sed -i "s/^${name}( strength\\* self )\$/${name}( strength* self, void* closure )/" "$KW_SRC/py/src/strength.cpp"
done

c1=$(grep -c "PyObject \*unused" "$KW_SRC/py/src/constraint.cpp" || true)
c2=$(grep -c "void\* closure" "$KW_SRC/py/src/strength.cpp" || true)
echo "kiwisolver METH_NOARGS/getset patched: constraint=$c1 (expect 4) strength=$c2 (expect 4)"
