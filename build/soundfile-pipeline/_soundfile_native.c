/* _soundfile_native — pure-C late-linked CPython extension wrapping libsndfile
 * for the eryx wasm32-wasip2 sandbox (path B of the soundfile worklog).
 *
 * Design constraints (see design_docs/code_interpreter_wasm_soundfile_build.md):
 *   - NO cffi, NO ctypes, NO dlopen, NO C++ exceptions, NO wasm closures.
 *   - Virtual I/O (file-like objects) via PyObject_CallMethod — normal C-API.
 *   - Raw samples are returned as `bytes`; the pure-Python soundfile shim wraps
 *     them with numpy (keeps this extension free of a numpy dependency).
 *   - Linked with wasi-sdk-27: -shared -fuse-ld=lld
 *     -Wl,--unresolved-symbols=import-dynamic $CROSS_PREFIX/lib/libpython3.14.so
 *     /tmp/wasi-build/libsndfile-build-static/libsndfile.a
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdint.h>
#include <string.h>
#include <sndfile.h>

/* ------------------------------------------------------------------ */
/* SoundFile handle type                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    PyObject_HEAD
    SNDFILE *snd;      /* NULL when closed */
    SF_INFO info;
    int mode;          /* SFM_READ / SFM_WRITE / SFM_RDWR */
    PyObject *fileobj; /* virtual-IO file object (borrowed semantics: owned ref) */
    int closed;
} SoundFileObject;

static PyTypeObject SoundFileType;

static SoundFileObject *
sf_handle_new(SNDFILE *snd, const SF_INFO *info, int mode, PyObject *fileobj)
{
    SoundFileObject *self = PyObject_New(SoundFileObject, &SoundFileType);
    if (self == NULL)
        return NULL;
    self->snd = snd;
    self->info = *info;
    self->mode = mode;
    self->fileobj = fileobj; /* takes ownership of the caller's reference */
    self->closed = 0;
    return self;
}

static PyObject *
sf_handle_raise_closed(void)
{
    PyErr_SetString(PyExc_ValueError, "I/O operation on closed sound file");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Virtual I/O callbacks (called synchronously by libsndfile, GIL held) */
/* ------------------------------------------------------------------ */

typedef struct {
    PyObject *fileobj;
} VioState;

static sf_count_t vio_get_filelen(void *user_data)
{
    VioState *v = (VioState *)user_data;
    /* measure length without disturbing the current position: libsndfile
     * calls get_filelen before reading the header and expects the file
     * cursor to stay put */
    PyObject *pos = PyObject_CallMethod(v->fileobj, "tell", NULL);
    if (pos == NULL) { PyErr_Clear(); return -1; }
    PyObject *r = PyObject_CallMethod(v->fileobj, "seek", "ii", 0, SEEK_END);
    if (r == NULL) { Py_DECREF(pos); PyErr_Clear(); return -1; }
    Py_DECREF(r);
    r = PyObject_CallMethod(v->fileobj, "tell", NULL);
    if (r == NULL) { Py_DECREF(pos); PyErr_Clear(); return -1; }
    sf_count_t len = (sf_count_t)PyLong_AsLongLong(r);
    Py_DECREF(r);
    r = PyObject_CallMethod(v->fileobj, "seek", "iL", 0, (long long)PyLong_AsLongLong(pos));
    Py_DECREF(pos);
    if (r == NULL) { PyErr_Clear(); return -1; }
    Py_DECREF(r);
    return len < 0 ? -1 : len;
}

static sf_count_t vio_seek(sf_count_t offset, int whence, void *user_data)
{
    VioState *v = (VioState *)user_data;
        PyObject *r = PyObject_CallMethod(v->fileobj, "seek", "ii", (long)offset, whence);
    if (r == NULL) { PyErr_Clear(); return -1; }
    Py_DECREF(r);
    r = PyObject_CallMethod(v->fileobj, "tell", NULL);
    if (r == NULL) { PyErr_Clear(); return -1; }
    sf_count_t pos = (sf_count_t)PyLong_AsLongLong(r);
    Py_DECREF(r);
    return pos < 0 ? -1 : pos;
}

static sf_count_t vio_read(void *ptr, sf_count_t count, void *user_data)
{
    VioState *v = (VioState *)user_data;
        PyObject *r = PyObject_CallMethod(v->fileobj, "read", "n", (Py_ssize_t)count);
    if (r == NULL) { PyErr_Clear(); return -1; }
    sf_count_t n = 0;
    if (PyBytes_Check(r)) {
        n = (sf_count_t)PyBytes_GET_SIZE(r);
        if (n > 0)
            memcpy(ptr, PyBytes_AS_STRING(r), (size_t)n);
    } else if (PyObject_CheckBuffer(r)) {
        Py_buffer view;
        if (PyObject_GetBuffer(r, &view, PyBUF_CONTIG_RO) == 0) {
            n = (sf_count_t)view.len;
            if (n > 0)
                memcpy(ptr, view.buf, (size_t)n);
            PyBuffer_Release(&view);
        } else {
            PyErr_Clear();
        }
    }
    Py_DECREF(r);
    return n;
}

static sf_count_t vio_write(const void *ptr, sf_count_t count, void *user_data)
{
    VioState *v = (VioState *)user_data;
    PyObject *b = PyBytes_FromStringAndSize((const char *)ptr, (Py_ssize_t)count);
    if (b == NULL)
        return -1;
    PyObject *r = PyObject_CallMethod(v->fileobj, "write", "O", b);
    Py_DECREF(b);
    if (r == NULL) { PyErr_Clear(); return -1; }
    sf_count_t n = (sf_count_t)PyLong_AsLongLong(r);
    Py_DECREF(r);
    return n < 0 ? -1 : n;
}

static sf_count_t vio_tell(void *user_data)
{
    VioState *v = (VioState *)user_data;
    PyObject *r = PyObject_CallMethod(v->fileobj, "tell", NULL);
    if (r == NULL) { PyErr_Clear(); return -1; }
    sf_count_t pos = (sf_count_t)PyLong_AsLongLong(r);
    Py_DECREF(r);
    return pos < 0 ? -1 : pos;
}

/* ------------------------------------------------------------------ */
/* module functions                                                    */
/* ------------------------------------------------------------------ */

static int
mode_to_sfm(const char *mode, int *out)
{
    if (strcmp(mode, "r") == 0) { *out = SFM_READ; return 0; }
    if (strcmp(mode, "r+") == 0) { *out = SFM_RDWR; return 0; }
    if (strcmp(mode, "w") == 0) { *out = SFM_WRITE; return 0; }
    if (strcmp(mode, "w+") == 0) { *out = SFM_RDWR; return 0; }
    PyErr_Format(PyExc_ValueError, "invalid mode %s (expected r, r+, w or w+)", mode);
    return -1;
}

static int
parse_info_args(PyObject *args, int *samplerate, int *channels, int *format)
{
    if (!PyArg_ParseTuple(args, "iii", samplerate, channels, format))
        return -1;
    return 0;
}

static PyObject *
py_sf_error(void)
{
    const char *msg = sf_strerror(NULL);
    PyErr_SetString(PyExc_OSError, msg ? msg : "libsndfile error");
    return NULL;
}

static PyObject *
soundfile_open(PyObject *self, PyObject *args)
{
    (void)self;
    const char *path, *mode;
    int samplerate = 0, channels = 0, format = 0;
    if (!PyArg_ParseTuple(args, "ss|iii", &path, &mode, &samplerate, &channels, &format))
        return NULL;
    int sfm;
    if (mode_to_sfm(mode, &sfm) < 0)
        return NULL;

    SF_INFO info;
    memset(&info, 0, sizeof(info));
    if (sfm != SFM_READ) {
        info.samplerate = samplerate;
        info.channels = channels;
        info.format = format;
    }
    SNDFILE *snd = sf_open(path, sfm, &info);
    if (snd == NULL)
        return py_sf_error();
    return (PyObject *)sf_handle_new(snd, &info, sfm, NULL);
}

static PyObject *
soundfile_open_virtual(PyObject *self, PyObject *args)
{
    (void)self;
    PyObject *fileobj;
    const char *mode;
    int samplerate = 0, channels = 0, format = 0;
    if (!PyArg_ParseTuple(args, "Os|iii", &fileobj, &mode, &samplerate, &channels, &format))
        return NULL;
    if (!PyObject_HasAttrString(fileobj, "read") || !PyObject_HasAttrString(fileobj, "seek") ||
        !PyObject_HasAttrString(fileobj, "tell")) {
        PyErr_SetString(PyExc_TypeError, "file object must support read/seek/tell (and write for w modes)");
        return NULL;
    }
    int sfm;
    if (mode_to_sfm(mode, &sfm) < 0)
        return NULL;

    SF_INFO info;
    memset(&info, 0, sizeof(info));
    if (sfm != SFM_READ) {
        info.samplerate = samplerate;
        info.channels = channels;
        info.format = format;
    }
    VioState *v = PyMem_Malloc(sizeof(VioState));
    if (v == NULL)
        return PyErr_NoMemory();
    v->fileobj = fileobj;
    SF_VIRTUAL_IO vio;
    memset(&vio, 0, sizeof(vio));
    vio.get_filelen = vio_get_filelen;
    vio.seek = vio_seek;
    vio.read = vio_read;
    vio.write = vio_write;
    vio.tell = vio_tell;

    SNDFILE *snd = sf_open_virtual(&vio, sfm, &info, v);
    if (snd == NULL) {
        PyMem_Free(v);
        return py_sf_error();
    }
    Py_INCREF(fileobj); /* handle owns a reference */
    SoundFileObject *handle = sf_handle_new(snd, &info, sfm, fileobj);
    if (handle == NULL) {
        sf_close(snd);
        Py_DECREF(fileobj);
        PyMem_Free(v);
        return NULL;
    }
    return (PyObject *)handle;
}

static SoundFileObject *
soundfile_check_handle(PyObject *obj)
{
    if (!PyObject_TypeCheck(obj, &SoundFileType)) {
        PyErr_SetString(PyExc_TypeError, "expected a SoundFile handle");
        return NULL;
    }
    SoundFileObject *self = (SoundFileObject *)obj;
    if (self->closed) {
        sf_handle_raise_closed();
        return NULL;
    }
    return self;
}

static PyObject *
soundfile_close(PyObject *self, PyObject *args)
{
    (void)args;
    SoundFileObject *h = soundfile_check_handle(self);
    if (h == NULL)
        return NULL;
    if (h->snd != NULL) {
        sf_close(h->snd);
        h->snd = NULL;
    }
    h->closed = 1;
    Py_CLEAR(h->fileobj);
    Py_RETURN_NONE;
}

static PyObject *
soundfile_info(PyObject *self, PyObject *args)
{
    (void)args;
    SoundFileObject *h = soundfile_check_handle(self);
    if (h == NULL)
        return NULL;
    return Py_BuildValue("{s:K,s:i,s:i,s:i,s:i,s:i}",
                         "frames", (unsigned long long)h->info.frames,
                         "samplerate", h->info.samplerate,
                         "channels", h->info.channels,
                         "format", h->info.format,
                         "sections", h->info.sections,
                         "seekable", h->info.seekable);
}

/* read helper: reads `frames` frames (frames<0 => all remaining) as `dtype`,
 * returns bytes. `readf` selects sf_readf_* (frames*channels samples). */
typedef sf_count_t (*read_fn)(SNDFILE *, void *, sf_count_t);
typedef sf_count_t (*readf_fn)(SNDFILE *, void *, sf_count_t);

static sf_count_t readf_short(SNDFILE *s, void *p, sf_count_t n) { return sf_readf_short(s, p, n); }
static sf_count_t readf_int(SNDFILE *s, void *p, sf_count_t n)   { return sf_readf_int(s, p, n); }
static sf_count_t readf_float(SNDFILE *s, void *p, sf_count_t n) { return sf_readf_float(s, p, n); }
static sf_count_t readf_double(SNDFILE *s, void *p, sf_count_t n) { return sf_readf_double(s, p, n); }

static PyObject *
soundfile_read(PyObject *self, PyObject *args)
{
    int dtype;      /* 0=short 1=int 2=float 3=double */
    long long frames = -1;
    if (!PyArg_ParseTuple(args, "i|L", &dtype, &frames))
        return NULL;
    SoundFileObject *h = soundfile_check_handle(self);
    if (h == NULL)
        return NULL;
    if (h->mode == SFM_WRITE) {
        PyErr_SetString(PyExc_RuntimeError, "cannot read from a file opened for writing");
        return NULL;
    }
    if (frames < 0) {
        sf_count_t cur = sf_seek(h->snd, 0, SEEK_CUR);
        sf_count_t end = sf_seek(h->snd, 0, SEEK_END);
        sf_seek(h->snd, cur, SEEK_SET);
        frames = end - cur;
        if (frames < 0) frames = 0;
    }
    size_t per = 1u;
    switch (dtype) {
        case 0: per = sizeof(short); break;
        case 1: per = sizeof(int); break;
        case 2: per = sizeof(float); break;
        case 3: per = sizeof(double); break;
        default: PyErr_SetString(PyExc_ValueError, "bad dtype code"); return NULL;
    }
    size_t total = (size_t)frames * (size_t)h->info.channels;
    if (total > (size_t)PY_SSIZE_T_MAX / per) {
        PyErr_SetString(PyExc_OverflowError, "read size overflow");
        return NULL;
    }
    Py_ssize_t nbytes = (Py_ssize_t)(total * per);
    PyObject *out = PyBytes_FromStringAndSize(NULL, nbytes);
    if (out == NULL)
        return NULL;
    readf_fn fn = dtype == 0 ? readf_short : dtype == 1 ? readf_int : dtype == 2 ? readf_float : readf_double;
    sf_count_t got = fn(h->snd, PyBytes_AS_STRING(out), (sf_count_t)frames);
    if (got < 0) {
        Py_DECREF(out);
        return py_sf_error();
    }
    Py_ssize_t used = (Py_ssize_t)((size_t)got * (size_t)h->info.channels * per);
    if (used < nbytes) {
        PyObject *trunc = PyBytes_FromStringAndSize(PyBytes_AS_STRING(out), used);
        Py_DECREF(out);
        return trunc;
    }
    return out;
}

/* write helper: `data` bytes hold frames*channels samples of `dtype` */
typedef sf_count_t (*writef_fn)(SNDFILE *, const void *, sf_count_t);
static sf_count_t writef_short(SNDFILE *s, const void *p, sf_count_t n) { return sf_writef_short(s, p, n); }
static sf_count_t writef_int(SNDFILE *s, const void *p, sf_count_t n)   { return sf_writef_int(s, p, n); }
static sf_count_t writef_float(SNDFILE *s, const void *p, sf_count_t n) { return sf_writef_float(s, p, n); }
static sf_count_t writef_double(SNDFILE *s, const void *p, sf_count_t n) { return sf_writef_double(s, p, n); }

static PyObject *
soundfile_write(PyObject *self, PyObject *args)
{
    PyObject *data;
    int dtype;
    if (!PyArg_ParseTuple(args, "Oi", &data, &dtype))
        return NULL;
    SoundFileObject *h = soundfile_check_handle(self);
    if (h == NULL)
        return NULL;
    if (h->mode == SFM_READ) {
        PyErr_SetString(PyExc_RuntimeError, "cannot write to a file opened for reading");
        return NULL;
    }
    Py_buffer view;
    if (PyObject_GetBuffer(data, &view, PyBUF_CONTIG_RO) < 0)
        return NULL;
    size_t per = 1u;
    writef_fn fn;
    switch (dtype) {
        case 0: per = sizeof(short); fn = writef_short; break;
        case 1: per = sizeof(int); fn = writef_int; break;
        case 2: per = sizeof(float); fn = writef_float; break;
        case 3: per = sizeof(double); fn = writef_double; break;
        default: PyBuffer_Release(&view); PyErr_SetString(PyExc_ValueError, "bad dtype code"); return NULL;
    }
    sf_count_t nframes = (sf_count_t)(view.len / per / (size_t)h->info.channels);
    sf_count_t got = fn(h->snd, view.buf, nframes);
    PyBuffer_Release(&view);
    if (got < 0)
        return py_sf_error();
    return PyLong_FromLongLong((long long)got);
}

static PyObject *
soundfile_seek(PyObject *self, PyObject *args)
{
    long long frames;
    int whence;
    if (!PyArg_ParseTuple(args, "Li", &frames, &whence))
        return NULL;
    SoundFileObject *h = soundfile_check_handle(self);
    if (h == NULL)
        return NULL;
    sf_count_t pos = sf_seek(h->snd, (sf_count_t)frames, whence);
    if (pos < 0)
        return py_sf_error();
    return PyLong_FromLongLong((long long)pos);
}

static PyObject *
soundfile_command(PyObject *self, PyObject *args)
{
    int cmd;
    long long value = 0;
    if (!PyArg_ParseTuple(args, "i|L", &cmd, &value))
        return NULL;
    SoundFileObject *h = soundfile_check_handle(self);
    if (h == NULL)
        return NULL;
    int r = sf_command(h->snd, cmd, &value, sizeof(value));
    return Py_BuildValue("(iL)", r, value);
}

static PyObject *
soundfile_strerror(PyObject *self, PyObject *args)
{
    (void)self;
    (void)args;
    const char *msg = sf_strerror(NULL);
    return PyUnicode_FromString(msg ? msg : "");
}

static PyObject *
soundfile_version(PyObject *self, PyObject *args)
{
    (void)self;
    (void)args;
    return PyUnicode_FromString(sf_version_string());
}

/* ------------------------------------------------------------------ */
/* module boilerplate                                                  */
/* ------------------------------------------------------------------ */

static void
SoundFile_dealloc(SoundFileObject *self)
{
    if (self->snd != NULL)
        sf_close(self->snd);
    Py_XDECREF(self->fileobj);
    Py_TYPE(self)->tp_free((PyObject *)self);
}

static PyObject *
SoundFile_repr(SoundFileObject *self)
{
    if (self->closed)
        return PyUnicode_FromFormat("<closed SoundFile>");
    return PyUnicode_FromFormat("<SoundFile: %d Hz, %d ch, format 0x%x>",
                                self->info.samplerate, self->info.channels, self->info.format);
}

static PyMethodDef SoundFile_methods[] = {
    {"close", soundfile_close, METH_VARARGS, "close() -> None"},
    {"info", soundfile_info, METH_VARARGS, "info() -> dict"},
    {"read", soundfile_read, METH_VARARGS, "read(dtype, frames=-1) -> bytes"},
    {"write", soundfile_write, METH_VARARGS, "write(data, dtype) -> frames written"},
    {"seek", soundfile_seek, METH_VARARGS, "seek(frames, whence) -> pos"},
    {"command", soundfile_command, METH_VARARGS, "command(cmd, value=0) -> (ok, value)"},
    {NULL, NULL, 0, NULL},
};

static PyTypeObject SoundFileType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "_soundfile_native.SoundFile",
    .tp_basicsize = sizeof(SoundFileObject),
    .tp_dealloc = (destructor)SoundFile_dealloc,
    .tp_repr = (reprfunc)SoundFile_repr,
    .tp_flags = Py_TPFLAGS_DEFAULT,
    .tp_methods = SoundFile_methods,
};

static PyMethodDef module_methods[] = {
    {"open", soundfile_open, METH_VARARGS,
     "open(path, mode, samplerate=0, channels=0, format=0) -> handle"},
    {"open_virtual", soundfile_open_virtual, METH_VARARGS,
     "open_virtual(fileobj, mode, samplerate=0, channels=0, format=0) -> handle"},
    {"strerror", soundfile_strerror, METH_NOARGS, "last libsndfile error text"},
    {"version", soundfile_version, METH_NOARGS, "libsndfile version string"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef moduledef = {
    PyModuleDef_HEAD_INIT, "_soundfile_native",
    "libsndfile binding for the wasm sandbox (path B)", -1, module_methods,
};

PyMODINIT_FUNC
PyInit__soundfile_native(void)
{
    if (PyType_Ready(&SoundFileType) < 0)
        return NULL;
    PyObject *m = PyModule_Create(&moduledef);
    if (m == NULL)
        return NULL;
    Py_INCREF(&SoundFileType);
    PyModule_AddObject(m, "SoundFile", (PyObject *)&SoundFileType);
    return m;
}
