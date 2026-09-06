@import GhosttyKit;
#import "Sources/TerminationWatchdogAtomic.h"

#include <ptrauth.h>
#include <stdint.h>

static inline uintptr_t CMUXStripCodePointer(uintptr_t address) {
#if defined(__arm64__)
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_function_pointer);
#else
    return address;
#endif
}
