//
//  SurrogatePeerContext.c
//  Surrogate
//
//  Created by Luke Howard on 20.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#include "SurrogateInternal.h"
#include "SurrogateHelpers.h"

static inline uint16_t
getPeerPort(const MOMPeerContext *peerContext)
{
    if (peerContext->peerAddress) {
        struct sockaddr_in *sin = (struct sockaddr_in *)CFDataGetBytePtr(peerContext->peerAddress);
        
        if (sin && sin->sin_family == AF_INET) {
            return ntohs(sin->sin_port);
        }
    }
    
    return 0;
}

static void *
__MOMPeerContextRetainStrong(MOMPeerContext *peerContext)
{
    if (atomic_fetch_add(&peerContext->retainCount, 1) < 1)
        __builtin_trap();
    
    return peerContext;
}

static void
__MOMPeerContextDealloc(MOMPeerContext *peerContext)
{
    _MOMDebugLog(CFSTR("destroying peer context %p {address = %@:%u}"),
           peerContext, peerContext->peerName, getPeerPort(peerContext));
    
    if (peerContext->peerAddress)
        CFRelease(peerContext->peerAddress);
    if (peerContext->peerName)
        CFRelease(peerContext->peerName);
    if (peerContext->readStream)
        CFRelease(peerContext->readStream);
    if (peerContext->writeStream)
        CFRelease(peerContext->writeStream);
    if (peerContext->readBuffer)
        CFRelease(peerContext->readBuffer);
    if (peerContext->writeBuffer)
        CFRelease(peerContext->writeBuffer);
    
    memset(peerContext, 0, sizeof(*peerContext));
    free(peerContext);
}

static void
__MOMPeerContextReleaseStrong(MOMPeerContext *peerContext)
{
    atomic_intptr_t oldRetainCount;
    
    oldRetainCount = atomic_fetch_sub(&peerContext->retainCount, 1);
    if (oldRetainCount > 1)
        return;
    else if (oldRetainCount < 1)
        __builtin_trap();

    __MOMPeerContextDealloc(peerContext);
}

void
_MOMPeerContextRelease(MOMPeerContext *peerContext)
{
    __MOMPeerContextReleaseStrong(peerContext);
}

static const void *
_MOMPeerContextRetain_CFArrayCallBacks(CFAllocatorRef allocator, const void *value)
{
    return __MOMPeerContextRetainStrong((MOMPeerContext *)value);
}

static void
_MOMPeerContextRelease_CFArrayCallBacks(CFAllocatorRef allocator, const void *value)
{
    __MOMPeerContextReleaseStrong((MOMPeerContext *)value);
}

static CFStringRef
_MOMPeerContextCopyDescription_CFArrayCallBacks(const void *value)
{
    const MOMPeerContext *peerContext = value;
    return CFStringCreateWithFormat(kCFAllocatorDefault, NULL,
                                    CFSTR("<MOMPeerContext %p {address = %@:%u}>"),
                                    peerContext,
                                    peerContext->peerName,
                                    getPeerPort(peerContext));
}

static Boolean
_MOMPeerContextEqual_CFArrayCallBacks(const void *v1, const void *v2)
{
    return v1 == v2;
}

void
_MOMSetPeerPortStatus(MOMControllerRef controller,
                      MOMPeerContext *peerContext,
                      MOMPortStatus status,
                      CFErrorRef error)
{
    MOMEvent event;
    CFMutableArrayRef params;
    
    switch (status) {
        case kMOMPortStatusClosed:
            event = error ? kMOMEventPortError : kMOMEventPortClosed;
            break;
        case kMOMPortStatusOpen:
            event = kMOMEventPortOpen;
            break;
        case kMOMPortStatusReady:
            event = kMOMEventPortReady;
            break;
        case kMOMPortStatusConnected:
            event = kMOMEventPortConnected;
            break;
        default:
            assert(0 && "invalid port status");
            break;
    }
    
    peerContext->portStatus = status;
    
    params = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(params, peerContext->peerName);
    if (error)
        CFArrayAppendValue(params, error);
    controller->handler(controller, event, params);
    CFRelease(params);
}

MOMPortStatus
_MOMGetPeerPortStatus(MOMControllerRef controller, MOMPeerContext *peerContext)
{
    return peerContext->portStatus;
}

static bool
_MOMPeerWriteBuffer(MOMPeerContext *peerContext)
{
    bool ret;
    
    assert(peerContext->writeBuffer);
    
    while (CFWriteStreamCanAcceptBytes(peerContext->writeStream) &&
           peerContext->bytesWritten < CFDataGetLength(peerContext->writeBuffer)) {
        peerContext->bytesWritten += CFWriteStreamWrite(peerContext->writeStream,
                                                        CFDataGetBytePtr(peerContext->writeBuffer) + peerContext->bytesWritten,
                                                        CFDataGetLength(peerContext->writeBuffer) - peerContext->bytesWritten);
        
    }
    
    ret = peerContext->bytesWritten == CFDataGetLength(peerContext->writeBuffer);
    if (ret) {
#if 0
        _MOMDebugLog(CFSTR("writing buffer to peer %p: %.*s"),
                     peerContext,
                     (int)CFDataGetLength(peerContext->writeBuffer), (char *)CFDataGetBytePtr(peerContext->writeBuffer));
#endif
        CFDataSetLength(peerContext->writeBuffer, 0);
        peerContext->bytesWritten = 0;
    }
    
    return ret;
}

static void
handleMessage(MOMPeerContext *peerContext, CFStringRef messageBuf)
{
    MOMEvent event = kMOMEventNone;
    CFMutableArrayRef eventParams = NULL;
    CFDataRef errorReply = NULL;
    
    if (CFStringGetLength(messageBuf) == 0)
        return;
    
    if (_MOMParseMessageString(messageBuf, &event, &eventParams, &errorReply) == kMOMStatusSuccess &&
        (event & kMOMEventTypeHostAny)) {
        _MOMProcessEvent(peerContext->controller, peerContext, event, eventParams);
    } else if (errorReply) {
        _MOMControllerEnqueueMessage(peerContext->controller, peerContext, errorReply);
    }
    
    if (eventParams)
        CFRelease(eventParams);
    if (errorReply)
        CFRelease(errorReply);
}

static void
handleMessages(MOMPeerContext *peerContext, CFArrayRef messages)
{
    if (messages != NULL) {
        CFIndex i;
        
        for (i = 0; i < CFArrayGetCount(messages); i++)
            handleMessage(peerContext, CFArrayGetValueAtIndex(messages, i));
    }
    
    _MOMPeerWriteBuffer(peerContext);
}

#define kMOMPeerContextCloseReadStream      1
#define kMOMPeerContextCloseWriteStream     2

static void
peerContextClose(MOMPeerContext *peerContext, uint32_t flags, CFErrorRef err)
{
    MOMControllerRef controller = peerContext->controller;

    if ((flags & kMOMPeerContextCloseReadStream) &&
        CFReadStreamGetStatus(peerContext->readStream) != kCFStreamStatusClosed) {
        if (_MOMPeerIsMaster(controller, peerContext))
            _MOMSetMasterPeer(controller, NULL);
        if (_MOMGetPeerPortStatus(controller, peerContext) >= kMOMPortStatusOpen)
            _MOMSetPeerPortStatus(controller, peerContext, kMOMPortStatusClosed, err);

        CFReadStreamUnscheduleFromRunLoop(peerContext->readStream, peerContext->controller->runLoop, kCFRunLoopCommonModes);
        CFReadStreamClose(peerContext->readStream);

        peerContext->lastActivity = 0; // force it to timeout
    }
    
    if ((flags & kMOMPeerContextCloseWriteStream) &&
        CFWriteStreamGetStatus(peerContext->writeStream) != kCFStreamStatusClosed) {
        CFWriteStreamUnscheduleFromRunLoop(peerContext->writeStream, peerContext->controller->runLoop, kCFRunLoopCommonModes);
        CFWriteStreamClose(peerContext->writeStream);
    }
}

static CFArrayRef
parseMessages(MOMPeerContext *peerContext)
{
    // XXX support \r\n
    if (CFStringGetCharacterAtIndex(peerContext->readBuffer, CFStringGetLength(peerContext->readBuffer) - 1) == '\r')
        return CFStringCreateArrayBySeparatingStrings(kCFAllocatorDefault, peerContext->readBuffer, CFSTR("\r"));
    
    return NULL;
}

static void
readStreamCallback(CFReadStreamRef readStream, CFStreamEventType eventType, void *userInfo)
{
    MOMPeerContext *peerContext = (MOMPeerContext *)userInfo;
    CFErrorRef err = NULL;
    
    switch (eventType) {
        case kCFStreamEventHasBytesAvailable: {
            uint8_t buf[1024];
            CFIndex bytesRead;
            CFArrayRef messages = NULL;

            time(&peerContext->lastActivity);

            bytesRead = CFReadStreamRead(readStream, buf, sizeof(buf));
            if (peerContext->readBuffer == NULL)
                peerContext->readBuffer = CFStringCreateMutable(kCFAllocatorDefault, bytesRead);
            
            if (bytesRead > 0) {
                CFStringRef readBuffer = CFStringCreateWithBytes(kCFAllocatorDefault,
                                                                 buf,
                                                                 bytesRead,
                                                                 kCFStringEncodingUTF8,
                                                                 true);
                if (readBuffer == NULL) {
                    // if we can't parse it, just ignore it
                    return;
                }
                CFStringAppend(peerContext->readBuffer, readBuffer);
                CFRelease(readBuffer);
            }
            
            if (CFStringGetLength(peerContext->readBuffer) == 0)
                break;

            messages = parseMessages(peerContext);
            if (messages) {
                handleMessages(peerContext, messages);
                CFRelease(messages);
                
                CFRelease(peerContext->readBuffer);
                peerContext->readBuffer = NULL;
            }
            break;
        }
        case kCFStreamEventErrorOccurred:
            err = CFReadStreamCopyError(readStream);
            /* fallthrough */
        case kCFStreamEventEndEncountered:
            peerContextClose(peerContext, kMOMPeerContextCloseReadStream, err);
            if (err)
                CFRelease(err);
            break;
        default:
            break;
    }
}

static void
writeStreamCallback(CFWriteStreamRef writeStream, CFStreamEventType eventType, void *userInfo)
{
    MOMPeerContext *peerContext = (MOMPeerContext *)userInfo;
    CFErrorRef err = NULL;
    
    switch (eventType) {
        case kCFStreamEventErrorOccurred: {
            err = CFWriteStreamCopyError(writeStream);
            /* fallthrough */
        }
        case kCFStreamEventEndEncountered:
            peerContextClose(peerContext, kMOMPeerContextCloseWriteStream, err);
            if (err)
                CFRelease(err);
            break;
        default:
            break;
    }
}

bool
_MOMHandleConnectionFromNewAddress(MOMControllerRef controller,
                                   CFDataRef peerAddress,
                                   CFStringRef peerName,
                                   CFReadStreamRef readStream,
                                   CFWriteStreamRef writeStream)
{
    CFStreamClientContext streamContext = {
        .version = 0,
    };
    MOMPeerContext *peerContext;

    if (readStream == NULL || writeStream == NULL)
        return false;
    
    peerContext = calloc(1, sizeof(*peerContext));
    if (peerContext == NULL)
        return false;
    
    peerContext->retainCount = 1;
    peerContext->controller = controller;
 
    peerContext->peerAddress = CFRetain(peerAddress);
    peerContext->peerName = CFRetain(peerName);
    streamContext.info = peerContext;

    peerContext->portStatus = kMOMPortStatusClosed;
    peerContext->lastActivity = 0;

    CFRetain(readStream);
    peerContext->readStream = readStream;
 
    CFReadStreamSetProperty(peerContext->readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    //this would once have allowed us to run in the background
    //CFReadStreamSetProperty(peerContext->readStream, kCFStreamNetworkServiceTypeVoIP, kCFBooleanTrue);
    CFReadStreamSetClient(peerContext->readStream,
                          kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered,
                          readStreamCallback, &streamContext);
    CFReadStreamScheduleWithRunLoop(peerContext->readStream, controller->runLoop, kCFRunLoopCommonModes);
    CFReadStreamOpen(peerContext->readStream);
    
    CFRetain(writeStream);
    peerContext->writeStream = writeStream;
    
    CFWriteStreamSetProperty(peerContext->writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetClient(peerContext->writeStream,
                           kCFStreamEventOpenCompleted | kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered,
                           writeStreamCallback, &streamContext);
    CFWriteStreamScheduleWithRunLoop(peerContext->writeStream, controller->runLoop, kCFRunLoopCommonModes);
    CFWriteStreamOpen(peerContext->writeStream);
    
    peerContext->writeBuffer = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CFArrayAppendValue(controller->peers, peerContext);
   
    _MOMDebugLog(CFSTR("new connection %p {address = %@:%u}"),
                 peerContext, peerContext->peerName, getPeerPort(peerContext));
    
    __MOMPeerContextReleaseStrong(peerContext);
    
    return true;
}

static void
possiblyExpirePeerContext(const void *value, void *context)
{
    MOMPeerContext *peerContext = (MOMPeerContext *)value;
    MOMControllerRef controller = peerContext->controller;
    CFMutableArrayRef nonExpiredPeers = (CFMutableArrayRef)context;
    time_t now = time(NULL);
    
    if (peerContext->lastActivity + controller->aliveTime < now) {
        _MOMDebugLog(CFSTR("expiring connection %p {address = %@:%u, idle = %d}"),
               peerContext,
               peerContext->peerName, getPeerPort(peerContext),
               peerContext->lastActivity ? now - peerContext->lastActivity : -1);
        peerContextClose(peerContext, kMOMPeerContextCloseReadStream | kMOMPeerContextCloseWriteStream, NULL);
    } else {
        CFArrayAppendValue(nonExpiredPeers, peerContext);
    }
}

bool
_MOMSetAliveTime(MOMControllerRef controller, int32_t aliveTime)
{
    CFRunLoopTimerRef timer;
    
    if (controller->aliveTime == aliveTime)
        return true;
    
    if (aliveTime < 1 || aliveTime > 60)
        return false;
    
    timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, 0, aliveTime, 0, 0,
                                            ^(CFRunLoopTimerRef timer) {
                                                CFMutableArrayRef nonExpiredPeers = _MOMCreatePeerContextArray(CFArrayGetCount(controller->peers));
                                                
                                                CFArrayApplyFunction(controller->peers,
                                                                     CFRangeMake(0, CFArrayGetCount(controller->peers)),
                                                                     possiblyExpirePeerContext,
                                                                     nonExpiredPeers);
                                                
                                                CFRelease(controller->peers);
                                                controller->peers = nonExpiredPeers;
                                            });
    
    if (controller->peerExpiryTimer) {
        CFRunLoopRemoveTimer(controller->runLoop, controller->peerExpiryTimer, kCFRunLoopCommonModes);
        CFRelease(controller->peerExpiryTimer);
    }
    
    controller->peerExpiryTimer = timer;
    controller->aliveTime = aliveTime;
    
    CFRunLoopAddTimer(controller->runLoop, controller->peerExpiryTimer, kCFRunLoopCommonModes);
    
    return true;
}

CFMutableArrayRef
_MOMCreatePeerContextArray(CFIndex capacity)
{
    CFArrayCallBacks peerContextCallBacks = {
        .version = 0,
        .retain = _MOMPeerContextRetain_CFArrayCallBacks,
        .release = _MOMPeerContextRelease_CFArrayCallBacks,
        .copyDescription =_MOMPeerContextCopyDescription_CFArrayCallBacks,
        .equal = _MOMPeerContextEqual_CFArrayCallBacks
    };
    
    return CFArrayCreateMutable(kCFAllocatorDefault, capacity, &peerContextCallBacks);
}

void
_MOMControllerEnqueueMessage(MOMControllerRef controller,
                             MOMPeerContext *peerContext,
                             CFDataRef messageBuf)
{
    assert(peerContext->writeBuffer);
    CFDataAppendBytes(peerContext->writeBuffer, CFDataGetBytePtr(messageBuf), CFDataGetLength(messageBuf));
}

MOMStatus
_MOMControllerSendToPeers(MOMControllerRef controller)
{
    CFIndex i;
    MOMStatus status = kMOMStatusRequiresMaster;
    
    if (CFArrayGetCount(controller->peers) == 0)
        return kMOMStatusSocketError;
    
    for (i = 0; i < CFArrayGetCount(controller->peers); i++) {
        MOMPeerContext *peerContext = (MOMPeerContext *)CFArrayGetValueAtIndex(controller->peers, i);
        
        if (_MOMPeerWriteBuffer(peerContext) &&
            _MOMPeerIsMaster(controller, peerContext))
            status = kMOMStatusSuccess;
    }
    
    return status;
}

bool
_MOMPeerIsMaster(MOMControllerRef controller, MOMPeerContext *peerContext)
{
    return peerContext == controller->peerMaster;
}

void
_MOMSetMasterPeer(MOMControllerRef controller, MOMPeerContext *peerContext)
{
    if (controller->peerMaster) {
        __MOMPeerContextReleaseStrong(controller->peerMaster);
        controller->peerMaster = NULL;
    }

    if (peerContext)
        controller->peerMaster = __MOMPeerContextRetainStrong(peerContext);
}

void
_MOMInvalidatePeers(MOMControllerRef controller)
{
    CFIndex i;

    for (i = 0; i < CFArrayGetCount(controller->peers); i++) {
        MOMPeerContext *peerContext = (MOMPeerContext *)CFArrayGetValueAtIndex(controller->peers, i);
        
        _MOMDebugLog(CFSTR("invalidating connection %p {address = %@:%u}"),
                     peerContext, peerContext->peerName, getPeerPort(peerContext));

        peerContextClose(peerContext, kMOMPeerContextCloseReadStream | kMOMPeerContextCloseWriteStream, NULL);
    }

    CFArrayRemoveAllValues(controller->peers);
}
