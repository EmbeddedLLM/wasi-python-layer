/* setjmp/longjmp shim: shadows wasi-sdk's setjmp.h (which #errors without
 * -mllvm -wasm-enable-sjlj, a lowering that emits wasm EH instructions the
 * runtime rejects — see build/extras/08-opencv.sh lesson). setjmp() always
 * returns 0; longjmp() traps. qhull uses setjmp only for its error-recovery
 * path, so normal operation is unaffected; degenerate-input errors abort the
 * sandbox instead of raising (recorded under the scipy boundary). */
#ifndef _SCIPY_SETJMP_SHIM_H
#define _SCIPY_SETJMP_SHIM_H
typedef char jmp_buf[64];
#ifdef __cplusplus
extern "C" {
#endif
int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);
#ifdef __cplusplus
}
#endif
#endif
