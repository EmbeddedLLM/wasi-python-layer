/* C++ exception ABI stubs for wasm32-wasi (wasi-sdk-27).
 *
 * wasi-sdk-27's libc++abi is built WITHOUT C++ exception support, so no wasi-sdk
 * library defines __cxa_throw / __cxa_allocate_exception / the _Unwind_* ABI. C++
 * extensions (numpy's _multiarray_umath + _pocketfft_umath, pandas' window/aggregations)
 * reference these and would leave them as imports eryx cannot late-link.
 *
 * Compile this file and link it into every C++ extension. Normal (non-throwing) code
 * paths never call these; an actual throw traps (a documented limitation).
 *
 * Usage (compile): clang --target=wasm32-wasip2 --sysroot=$SYSROOT -fPIC -c cxx_eh_stub.c -o cxx_eh_stub.o
 * Usage (link):    add cxx_eh_stub.o (and -lc++) to the extension's link line.
 */
#include <stddef.h>

static char exc_buf[8192];

void *__cxa_allocate_exception(size_t s) { (void)s; return exc_buf; }
void __cxa_free_exception(void *e) { (void)e; }
void __cxa_throw(void *a, void *b, void *c) { (void)a; (void)b; (void)c; __builtin_trap(); }
void __cxa_rethrow(void) { __builtin_trap(); }
void *__cxa_begin_catch(void *e) { return e; }
void __cxa_end_catch(void) {}
void *__cxa_get_exception_ptr(void *e) { return e; }
int __cxa_uncaught_exception(void) { return 0; }
unsigned int __cxa_uncaught_exceptions(void) { return 0; }
void __cxa_call_unexpected(void *e) { (void)e; __builtin_trap(); }
void __cxa_call_terminate(void *e) { (void)e; __builtin_trap(); }
void _Unwind_Resume(void *e) { (void)e; __builtin_trap(); }
void _Unwind_Complete(void *e) { (void)e; }
int _Unwind_RaiseException(void *e) { (void)e; __builtin_trap(); return 0; }
void _Unwind_DeleteException(void *e) { (void)e; }
