#ifndef DELTA_SECURITY_H
#define DELTA_SECURITY_H

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stddef.h>

OSStatus DeltaCreateTrustedApplicationAccess(
    const char * _Nonnull const * _Nonnull paths,
    size_t pathCount,
    CFStringRef _Nonnull promptName,
    SecAccessRef _Nullable * _Nonnull accessOut
);

#endif
