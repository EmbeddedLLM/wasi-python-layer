/* longjmp is a trap stub (the sandbox cannot unwind); setjmp never triggers
 * the error path. Linked into every scipy extension via c_link_args. */
#include "setjmp.h"
int setjmp(jmp_buf env) { (void)env; return 0; }
void longjmp(jmp_buf env, int val) { (void)env; (void)val; __builtin_trap(); }
