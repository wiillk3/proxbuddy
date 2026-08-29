//-----------------------------------------------------------------------------
// ProxBuddy — in-process libpm3 must not call libc exit().
// Thread-local longjmp target armed around pm3_open / pm3_console / pm3_close
// (client) or the helper-tool main wrapper. See pm3_ios_exit.c.
//-----------------------------------------------------------------------------
#ifndef PM3_IOS_EXIT_H
#define PM3_IOS_EXIT_H

#include <setjmp.h>

#ifdef __cplusplus
extern "C" {
#endif

extern _Thread_local jmp_buf pm3_ios_exit_jmp;
extern _Thread_local int pm3_ios_exit_armed;
extern _Thread_local int pm3_ios_exit_status;

void pm3_ios_exit(int status);

#ifdef __cplusplus
}
#endif

#endif
