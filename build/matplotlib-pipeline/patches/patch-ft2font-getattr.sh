#!/bin/bash
# Patch ft2font_wrapper.cpp: replace pybind11 __getattr__ with raw CPython function.
# pybind11's __getattr__ uses C++ exceptions (throw py::attribute_error) which trap
# on WASI. A raw CPython PyCFunction uses PyErr_SetString + return NULL instead.
# Idempotent: checks for the marker before patching.
set -euo pipefail
MPL_SRC="${1:?usage: patch-ft2font-getattr.sh <mpl-src> <mpl-build>}"
FILE="$MPL_SRC/src/ft2font_wrapper.cpp"

if grep -q "ft2font_module_getattr" "$FILE" 2>/dev/null; then
    echo "  [skip] ft2font __getattr__ already patched"
    exit 0
fi

echo "  [patch] ft2font_wrapper.cpp: raw CPython __getattr__"

python3 - "$FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# 1. Add raw C __getattr__ before PYBIND11_MODULE
raw_getattr = '''
// Raw CPython __getattr__ — avoids C++ exceptions (WASI has no EH support).
static PyObject *
ft2font_module_getattr(PyObject *module, PyObject *name_obj)
{
    const char *name = PyUnicode_AsUTF8(name_obj);
    if (!name) return NULL;
    PyErr_Format(PyExc_AttributeError,
                 "module 'matplotlib.ft2font' has no attribute '%s'", name);
    return NULL;
}

static PyMethodDef ft2font_module_getattr_def = {
    "__getattr__", (PyCFunction)ft2font_module_getattr, METH_O, NULL
};

'''
content = content.replace(
    "PYBIND11_MODULE(ft2font, m, py::mod_gil_not_used())",
    raw_getattr + "PYBIND11_MODULE(ft2font, m, py::mod_gil_not_used())"
)

# 2. Replace m.def("__getattr__", ...) with raw C version
content = content.replace(
    '    m.def("__getattr__", ft2font__getattr__);',
    '''    // Raw CPython __getattr__ (no C++ exceptions on WASI)
    {
        PyObject *getattr_func = PyCFunction_New(&ft2font_module_getattr_def, m.ptr());
        if (getattr_func) {
            PyObject_SetAttrString(m.ptr(), "__getattr__", getattr_func);
            Py_DECREF(getattr_func);
        }
    }'''
)

# 3. Replace throw py::attribute_error in __getattr__ with PyErr + return
content = content.replace(
    '''    throw py::attribute_error(
        "module 'matplotlib.ft2font' has no attribute {!r}"_s.format(name));''',
    '''    PyErr_SetString(PyExc_AttributeError,
        ("module 'matplotlib.ft2font' has no attribute '" + name + "'").c_str());
    return py::object();'''
)

# 4. Replace throw std::runtime_error in module init
content = content.replace(
    '        throw std::runtime_error("Could not initialize the freetype2 library");',
    '''        PyErr_SetString(PyExc_RuntimeError, "Could not initialize the freetype2 library");
        return;'''
)

with open(path, 'w') as f:
    f.write(content)
print("  [done] ft2font_wrapper.cpp patched")
PYEOF
