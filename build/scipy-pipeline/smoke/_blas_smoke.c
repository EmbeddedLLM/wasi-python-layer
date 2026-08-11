/*
 * _blas_smoke — tiny CPython extension proving BLAS/LAPACK inside Eryx,
 * independently of SciPy (plan Stage 4-6 / M4-M7).
 *
 * P11 ABI gate (plan Stage 0.1 / Stage 5): every METH_NOARGS handler takes
 * exactly (PyObject *self, PyObject *unused) — wasm32 call_indirect
 * type-checks arity (cf. the Pillow/kiwisolver traps, design_docs
 * code_interpreter_wasm_webp_got_trap.md §10). Compile with
 * -Wcast-function-type-strict and keep the table clean.
 *
 * Fortran BLAS/LAPACK symbols, LP64 f2c ABI:
 *   dgemm_(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)
 *   dgesv_(n, nrhs, a, lda, ipiv, b, ldb, info)
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

extern int dgemm_(char *ta, char *tb, int *m, int *n, int *k,
                  double *alpha, double *a, int *lda, double *b, int *ldb,
                  double *beta, double *c, int *ldc);
extern int dgesv_(int *n, int *nrhs, double *a, int *lda, int *ipiv,
                  double *b, int *ldb, int *info);

static PyObject *
smoke_dgemm(PyObject *self, PyObject *unused)
{
    /* A = [[1,2],[3,4]], B = [[5,6],[7,8]] -> C = A@B = [[19,22],[43,50]] */
    double A[4] = {1.0, 3.0, 2.0, 4.0};  /* column-major */
    double B[4] = {5.0, 7.0, 6.0, 8.0};
    double C[4] = {0.0, 0.0, 0.0, 0.0};
    char ta = 'N', tb = 'N';
    int m = 2, n = 2, k = 2, lda = 2, ldb = 2, ldc = 2;
    double alpha = 1.0, beta = 0.0;

    dgemm_(&ta, &tb, &m, &n, &k, &alpha, A, &lda, B, &ldb, &beta, C, &ldc);

    /* C is column-major: C[0]=C11, C[1]=C21, C[2]=C12, C[3]=C22.
     * Return row-major order to match the plan's expectation
     * (19.0, 22.0, 43.0, 50.0). */
    return Py_BuildValue("(dddd)", C[0], C[2], C[1], C[3]);
}

static PyObject *
smoke_dgesv(PyObject *self, PyObject *unused)
{
    /* 3x + y = 9 ; x + 2y = 8  ->  x = 2, y = 3 */
    double a[4] = {3.0, 1.0, 1.0, 2.0};  /* column-major [[3,1],[1,2]] */
    double b[2] = {9.0, 8.0};
    int n = 2, nrhs = 1, lda = 2, ldb = 2, info = 0;
    int ipiv[2] = {0, 0};

    dgesv_(&n, &nrhs, a, &lda, ipiv, b, &ldb, &info);
    if (info != 0)
        return PyErr_Format(PyExc_RuntimeError, "dgesv info=%d", info);

    return Py_BuildValue("(dd)", b[0], b[1]);
}

static PyMethodDef smoke_methods[] = {
    {"dgemm", smoke_dgemm, METH_NOARGS,
     "A=[[1,2],[3,4]], B=[[5,6],[7,8]] -> (19.0, 22.0, 43.0, 50.0)"},
    {"dgesv", smoke_dgesv, METH_NOARGS,
     "3x+y=9, x+2y=8 -> (2.0, 3.0)"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef smoke_module = {
    PyModuleDef_HEAD_INIT,
    "_blas_smoke",
    "BLAS/LAPACK substrate probe (dgemm_/dgesv_ via libopenblas.a + libf2c.a).",
    -1,
    smoke_methods,
};

PyMODINIT_FUNC
PyInit__blas_smoke(void)
{
    return PyModule_Create(&smoke_module);
}
