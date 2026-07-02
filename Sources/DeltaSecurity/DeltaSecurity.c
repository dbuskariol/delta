#include "DeltaSecurity.h"

OSStatus DeltaCreateTrustedApplicationAccess(
    const char * const * paths,
    size_t pathCount,
    CFStringRef promptName,
    SecAccessRef * accessOut
) {
    if (paths == NULL || pathCount == 0 || promptName == NULL || accessOut == NULL) {
        return errSecParam;
    }

    CFMutableArrayRef trustedApplications = CFArrayCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeArrayCallBacks
    );
    if (trustedApplications == NULL) {
        return errSecAllocate;
    }

    OSStatus status = errSecSuccess;
    for (size_t index = 0; index < pathCount; index += 1) {
        SecTrustedApplicationRef application = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        status = SecTrustedApplicationCreateFromPath(paths[index], &application);
#pragma clang diagnostic pop
        if (status != errSecSuccess || application == NULL) {
            CFRelease(trustedApplications);
            return status;
        }
        CFArrayAppendValue(trustedApplications, application);
        CFRelease(application);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = SecAccessCreate(promptName, trustedApplications, accessOut);
#pragma clang diagnostic pop
    CFRelease(trustedApplications);
    return status;
}
