/* C++ exception / unwind ABI stubs for wasm32-wasi — same pattern as the
 * pandas pipeline's cxx_eh_stub.c (wasi-sdk's libc++abi has no exception
 * support). Normal (non-throwing) paths never call these; an actual throw
 * traps.
 *
 * POLICY (2026-08-10, rewritten after the trap-thunk investigation): this
 * stub defines ONLY symbols the runtime's base libraries cannot provide.
 * Everything the erics runtime already exports from libc++.so / libc++abi.so
 * / libc.so (std::mutex, std::thread, basic_string, exception_ptr,
 * __shared_weak_count, to_string, operator+, __cxa_uncaught_exception(s),
 * pthread_create/keys, ...) MUST NOT be defined here: a conflicting
 * definition with a different wasm signature makes wasm-ld emit a
 * `signature_mismatch:` TRAP THUNK (body = `unreachable; end`) that traps at
 * runtime — silent at link time, fatal at import/call (observed in
 * pyduccfft's PyInit via pybind11 get_internals -> mutex::lock, 2026-08-10).
 *
 * The full libc++ surface was originally stubbed here "for completeness" and
 * produced exactly that class of trap in all 10 C++ extensions. Removed.
 *
 * Compile: clang --target=wasm32-wasip2 --sysroot=$SYSROOT -fPIC -c
 * Link: add cxx_eh_stub.o to every C++ extension's link line.
 */
#include <stddef.h>

static char exc_buf[8192];

void *__cxa_allocate_exception(size_t s) { (void)s; return exc_buf; }
void __cxa_free_exception(void *e) { (void)e; }
void __cxa_throw(void *a, void *b, void *c) { (void)a; (void)b; (void)c; __builtin_trap(); }
void *__cxa_init_primary_exception(void *a, void *b, void *c) {
    (void)a; (void)b; (void)c; return exc_buf;
}
void __cxa_rethrow(void) { __builtin_trap(); }
void *__cxa_begin_catch(void *e) { return e; }
void __cxa_end_catch(void) {}
void *__cxa_get_exception_ptr(void *e) { return e; }
void __cxa_call_unexpected(void *e) { (void)e; __builtin_trap(); }
void __cxa_call_terminate(void *e) { (void)e; __builtin_trap(); }
void _Unwind_Resume(void *e) { (void)e; __builtin_trap(); }
void _Unwind_Complete(void *e) { (void)e; }
int _Unwind_RaiseException(void *e) { (void)e; __builtin_trap(); return 0; }
void _Unwind_DeleteException(void *e) { (void)e; }

/* wasi has no fork; never called in practice. Not provided by base libc. */
int pthread_atfork(void (*prepare)(void), void (*parent)(void),
                   void (*child)(void)) {
    (void)prepare; (void)parent; (void)child;
    return 0;
}
