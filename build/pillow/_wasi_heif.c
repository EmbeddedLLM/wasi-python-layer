/*
 * Minimal HEIC/HEIF decoder for the wasm32-wasip2 site-packages layer.
 *
 * Why this exists: Pillow core has no HEIF support in any version, and the
 * cffi route (pillow-heif) is unavailable on wasip2 — cffi's _cffi_backend
 * links libffi, whose wasm32 port is emscripten-only (EM_JS wasm-table glue)
 * and cannot be built for wasip2. This extension calls libheif directly
 * (decode-only, HEVC via libde265) and hands the RGBA plane to PIL.
 * Mirrors the repo's _soundfile_native.c pattern
 * (build/soundfile-pipeline/03-extension.sh).
 *
 * Exposes one function:
 *   decode(data: bytes) -> (width: int, height: int, stride: int, rgba: bytes)
 * Raises ValueError on malformed input or decode failure.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <libheif/heif.h>

static PyObject *
wasi_heif_decode(PyObject *self, PyObject *args)
{
    const char *data;
    Py_ssize_t size;
    struct heif_context *ctx = NULL;
    struct heif_image_handle *handle = NULL;
    struct heif_image *image = NULL;
    struct heif_error err;
    PyObject *result = NULL;
    int w = 0, h = 0, stride = 0;
    const uint8_t *plane = NULL;

    if (!PyArg_ParseTuple(args, "y#", &data, &size))
        return NULL;

    ctx = heif_context_alloc();
    if (!ctx) {
        PyErr_SetString(PyExc_RuntimeError, "heif_context_alloc failed");
        goto done;
    }

    err = heif_context_read_from_memory_without_copy(ctx, data, size, NULL);
    if (err.code != heif_error_Ok) {
        PyErr_Format(PyExc_ValueError, "heif read: %s", err.message);
        goto done;
    }

    err = heif_context_get_primary_image_handle(ctx, &handle);
    if (err.code != heif_error_Ok) {
        PyErr_Format(PyExc_ValueError, "heif: %s", err.message);
        goto done;
    }

    /* libheif >= 1.15: width/height return int directly. */
    w = heif_image_handle_get_width(handle);
    h = heif_image_handle_get_height(handle);

    err = heif_decode_image(handle, &image, heif_colorspace_RGB,
                            heif_chroma_interleaved_RGBA, NULL);
    if (err.code != heif_error_Ok) {
        PyErr_Format(PyExc_ValueError, "heif decode: %s", err.message);
        goto done;
    }

    plane = heif_image_get_plane_readonly(image, heif_channel_interleaved,
                                          &stride);
    if (!plane) {
        PyErr_SetString(PyExc_ValueError, "heif: no interleaved RGBA plane");
        goto done;
    }
    if (stride < w * 4) {
        PyErr_SetString(PyExc_ValueError, "heif: unexpected plane stride");
        goto done;
    }

    /* Copy the plane (incl. row padding) into a fresh bytes object. */
    result = Py_BuildValue("(iiiy#)", w, h, stride, plane,
                           (Py_ssize_t)((size_t)stride * (size_t)h));

done:
    if (image)
        heif_image_release(image);
    if (handle)
        heif_image_handle_release(handle);
    if (ctx)
        heif_context_free(ctx);
    return result;
}

static PyMethodDef wasi_heif_methods[] = {
    {"decode", wasi_heif_decode, METH_VARARGS,
     "Decode HEIC/HEIF bytes -> (width, height, stride, rgba bytes)."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef wasi_heif_module = {
    PyModuleDef_HEAD_INIT,
    "_wasi_heif",
    "HEIC/HEIF decoder (libheif + libde265, decode-only).",
    -1,
    wasi_heif_methods,
};

PyMODINIT_FUNC
PyInit__wasi_heif(void)
{
    return PyModule_Create(&wasi_heif_module);
}
