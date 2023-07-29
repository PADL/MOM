//
//  SurrogateResolver.c
//  Surrogate
//
//  Created by Luke Howard on 06.06.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#include "SurrogateInternal.h"

#ifdef __APPLE__
static void
__CFHostPerformBlock(CFHostRef host, CFHostInfoType typeInfo, const CFStreamError *error, void *info)
{
    void (^block)(CFHostRef host, CFHostInfoType typeInfo, const CFStreamError *error) = info;
    block(host, typeInfo, error);
}

static void
CFHostSetClientBlock(CFHostRef host, void (^block)(CFHostRef host, CFHostInfoType typeInfo, const CFStreamError *error))
{
    CFHostClientContext hostClientContext = {
        .version = 0,
        .info = block,
        .retain = (const void * (*)(const void *))_Block_copy,
        .release = _Block_release
    };

    CFHostSetClient(host, __CFHostPerformBlock, &hostClientContext);
}
#endif /* __APPLE__ */

void
_MOMResolveHostRestrictionAndPerform(MOMControllerRef controller,
                                     void (^withResolvedHost)(MOMControllerRef controller, CFArrayRef restrictAddressList))
{
    CFStringRef hostRestriction = CFDictionaryGetValue(controller->options, kMOMRestrictToSpecifiedHost);
    
    if (hostRestriction) {
        const char *ipAddr = CFStringGetCStringPtr(hostRestriction, kCFStringEncodingUTF8);
        struct sockaddr_in sin = {
            .sin_family = AF_INET,
#ifdef __APPLE__
            .sin_len = sizeof(sin)
#endif
        };

        if (ipAddr && inet_pton(AF_INET, ipAddr, &sin.sin_addr) != 0) {
            // fast path, or if we don't have CFHost
            CFDataRef address = CFDataCreate(kCFAllocatorDefault, (uint8_t *)&sin, sizeof(sin));
            CFArrayRef addressList = CFArrayCreate(kCFAllocatorDefault, (const void **)&address, 1, &kCFTypeArrayCallBacks);
            withResolvedHost(controller, addressList);
            CFRelease(addressList);
            CFRelease(address);
#ifdef __APPLE__
        } else {
            CFHostRef host = CFHostCreateWithName(kCFAllocatorDefault, hostRestriction);
            CFStreamError streamError;
            
            MOMControllerRetain(controller);
            CFHostSetClientBlock(host, ^(CFHostRef host, CFHostInfoType typeInfo, const CFStreamError *error) {
                Boolean bResolved = false;
                CFArrayRef addresses = CFHostGetAddressing(host, &bResolved);
                
                withResolvedHost(controller, addresses);
                
                CFHostSetClient(host, NULL, NULL);
                CFHostUnscheduleFromRunLoop(host, controller->runLoop, kCFRunLoopCommonModes);
                MOMControllerRelease(controller);
            });
            CFHostScheduleWithRunLoop(host, controller->runLoop, kCFRunLoopCommonModes);
            CFHostStartInfoResolution(host, kCFHostAddresses, &streamError);
            CFRelease(host);
#endif
        }
    } else {
        withResolvedHost(controller, NULL);
    }
}
