//-----------------------------------------------------------------------------
// Force-included when building libpm3client and the iOS helper tools.
// Rewrites libc exit() so the in-process client cannot terminate ProxBuddy.
//-----------------------------------------------------------------------------
#ifndef PM3_IOS_NO_PROCESS_EXIT_H
#define PM3_IOS_NO_PROCESS_EXIT_H

#ifndef PM3_IOS_EXIT_IMPLEMENTATION

#ifdef __cplusplus
extern "C" {
#endif
void pm3_ios_exit(int status);
#ifdef __cplusplus
}
#endif

#ifdef exit
#undef exit
#endif
#define exit(status) pm3_ios_exit(status)

#endif /* PM3_IOS_EXIT_IMPLEMENTATION */

#endif
