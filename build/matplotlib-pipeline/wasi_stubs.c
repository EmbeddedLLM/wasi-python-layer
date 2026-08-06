/* wasi_stubs.c — C++ exception ABI stubs for WASI (no EH runtime).
 * Normal operation never throws; an actual throw traps.
 */
#include <stdint.h>
#include <stdlib.h>

static char eh_buffer[4096];

void *__cxa_allocate_exception(unsigned long thrown_size) {
    (void)thrown_size;
    return eh_buffer;
}

void __cxa_throw(void *thrown_exception, void *tinfo, void (*dest)(void *)) {
    (void)thrown_exception; (void)tinfo; (void)dest;
    __builtin_trap();
}

void *__cxa_begin_catch(void *exception_object) {
    (void)exception_object;
    return NULL;
}

void __cxa_end_catch(void) {}

void _Unwind_Resume(void *exception_object) {
    (void)exception_object;
    __builtin_trap();
}
