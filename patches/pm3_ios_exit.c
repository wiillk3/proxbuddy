//-----------------------------------------------------------------------------
// ProxBuddy — replacement for libc exit() inside libpm3client / helper tools.
//
// The C client runs on the "pm3-libpm3" thread. libc exit() would take down
// the whole iOS process (session log, in-flight dumps, UI). When a trap is
// armed we longjmp back to pm3_open / pm3_console / pm3_close (or the helper
// main wrapper) instead. With no trap we pthread_exit the current thread
// rather than the process; on the main thread we refuse to die at all.
//-----------------------------------------------------------------------------
#define PM3_IOS_EXIT_IMPLEMENTATION
#include "pm3_ios_exit.h"

#include <stdio.h>
#include <pthread.h>
#include <stdint.h>

_Thread_local jmp_buf pm3_ios_exit_jmp;
_Thread_local int pm3_ios_exit_armed;
_Thread_local int pm3_ios_exit_status;

void pm3_ios_exit(int status) {
    if (pm3_ios_exit_armed) {
#ifdef PM3_IOS_TOOL_WRAP
        if (status != 0) {
            fprintf(stdout, "\n[!] helper tool: exit(%d) intercepted\n", status);
            fflush(stdout);
        }
#else
        fprintf(stdout, "\n[!] libpm3: exit(%d) intercepted — ending the client session, not the app\n", status);
        fflush(stdout);
#endif
        pm3_ios_exit_status = status;
        longjmp(pm3_ios_exit_jmp, 1);
    }

    fprintf(stderr, "[libpm3] exit(%d) with no session trap; not terminating the process\n", status);
    fflush(stderr);
    if (pthread_main_np()) {
        return;
    }
    pthread_exit((void *)(intptr_t)status);
}

#ifdef PM3_IOS_TOOL_WRAP
int PM3_IOS_TOOL_INNER(int argc, char **argv);
int PM3_IOS_TOOL_WRAP(int argc, char **argv) {
    if (setjmp(pm3_ios_exit_jmp)) {
        pm3_ios_exit_armed = 0;
        return pm3_ios_exit_status;
    }
    pm3_ios_exit_armed = 1;
    int rc = PM3_IOS_TOOL_INNER(argc, argv);
    pm3_ios_exit_armed = 0;
    return rc;
}
#endif
