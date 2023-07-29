//
//  SurrogateLogging.c
//  Surrogate
//
//  Created by Luke Howard on 22.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#include "SurrogateInternal.h"

#if __APPLE__

extern void NSLogv(CFStringRef format, va_list args);

#else

typedef void (*CFLogFunc)(int32_t lev, const char *message, size_t length, char withBanner);

CF_EXPORT void
_CFLogvEx2(CFLogFunc logit,
           CFStringRef (*copyDescFunc)(void *, const void *),
           CFStringRef (*contextDescFunc)(void *, const void *, const void *, bool, bool *),
           CFDictionaryRef formatOptions, int32_t lev, CFStringRef format, va_list args);
#endif

void _MOMDebugLog(CFStringRef format, ...)
{
    va_list args;
    va_start(args, format);
#ifdef __APPLE__
    NSLogv(format, args);
#else
    _CFLogvEx2(NULL, NULL, NULL, NULL, kCFLogLevelInfo, format, args);
#endif
    va_end(args);
}
