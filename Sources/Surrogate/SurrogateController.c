//
//  SurrogateContext.c
//  Surrogate
//
//  Created by Luke Howard on 15.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#include "SurrogateInternal.h"
#include "SurrogateHelpers.h"

#if MOM_STREAMDECK_PLUGIN
const CFStringRef kMOMDeviceID                  = CFSTR("device_id");
const CFStringRef kMOMDeviceName                = CFSTR("device_name");
const CFStringRef kMOMSerialNumber              = CFSTR("serial_number");
const CFStringRef kMOMModelID                   = CFSTR("model_id");
const CFStringRef kMOMSystemTypeAndVersion      = CFSTR("system_type_and_version");
const CFStringRef kMOMRestrictToSpecifiedHost   = CFSTR("restrict_to_specified_host");
const CFStringRef kMOMCPUFirmwareTag            = CFSTR("cpu_firmware_tag");
const CFStringRef kMOMCPUFirmwareVersion        = CFSTR("cpu_firmware_version");
const CFStringRef kMOMRecoveryFirmwareTag       = CFSTR("recovery_firmware_tag");
const CFStringRef kMOMRecoveryFirmwareVersion   = CFSTR("recovery_firmware_version");
const CFStringRef kMOMLocalInterfaceAddress     = CFSTR("local_interface_address");

#else
const CFStringRef kMOMDeviceID                  = CFSTR("kMOMDeviceID");
const CFStringRef kMOMDeviceName                = CFSTR("kMOMDeviceName");
const CFStringRef kMOMSerialNumber              = CFSTR("kMOMSerialNumber");
const CFStringRef kMOMModelID                   = CFSTR("kMOMModelID");
const CFStringRef kMOMSystemTypeAndVersion      = CFSTR("kMOMSystemTypeAndVersion");
const CFStringRef kMOMRestrictToSpecifiedHost   = CFSTR("kMOMRestrictToSpecifiedHost");
const CFStringRef kMOMCPUFirmwareTag            = CFSTR("kMOMCPUFirmwareTag");
const CFStringRef kMOMCPUFirmwareVersion        = CFSTR("kMOMCPUFirmwareVersion");
const CFStringRef kMOMRecoveryFirmwareTag       = CFSTR("kMOMRecoveryFirmwareTag");
const CFStringRef kMOMRecoveryFirmwareVersion   = CFSTR("kMOMRecoveryFirmwareVersion");
const CFStringRef kMOMLocalInterfaceAddress     = CFSTR("kMOMLocalInterfaceAddress");
#endif /* !MOM_STREAMDECK_PLUGIN */

static void *
__MOMControllerRetainStrong(MOMControllerRef controller)
{
    if (atomic_fetch_add(&controller->retainCount, 1) < 1)
        __builtin_trap();

    return controller;
}

static void
__MOMControllerDealloc(MOMControllerRef controller)
{
    MOMControllerEndDiscoverability(controller);
    
    if (controller->peers) {
        CFRelease(controller->peers);
    }
    if (controller->handler) {
        _Block_release(controller->handler);
    }
    if (controller->options) {
        CFRelease(controller->options);
    }
    if (controller->peerExpiryTimer) {
        CFRunLoopRemoveTimer(controller->runLoop, controller->peerExpiryTimer, kCFRunLoopCommonModes);
        CFRelease(controller->peerExpiryTimer);
    }
    if (controller->runLoop) {
        CFRelease(controller->runLoop);
    }
    
    memset(controller, 0, sizeof(*controller));
    free(controller);
}

static void
__MOMControllerReleaseStrong(MOMControllerRef controller)
{
    atomic_intptr_t oldRetainCount;
    
    oldRetainCount = atomic_fetch_sub(&controller->retainCount, 1);
    if (oldRetainCount > 1)
        return;
    else if (oldRetainCount < 1)
        __builtin_trap();

    __MOMControllerDealloc(controller);
}

static const void *
_MOMControllerRetain_CFAllocatorContext(const void *value)
{
    return __MOMControllerRetainStrong((MOMControllerRef)value);
}

static void
_MOMControllerRelease_CFAllocatorContext(const void *value)
{
    __MOMControllerReleaseStrong((MOMControllerRef)value);
}

static CFStringRef
_MOMControllerCopyDescription_CFAllocatorContext(const void *value)
{
    MOMControllerRef controller = (MOMControllerRef)value;
    
    return CFStringCreateWithFormat(CFGetAllocator(controller), NULL, CFSTR("<MOMController %p"), controller);
}

const CFSocketContext _MOMControllerSocketContext = {
    .version = 0,
    .info = NULL,
    .retain = _MOMControllerRetain_CFAllocatorContext,
    .release = _MOMControllerRelease_CFAllocatorContext,
    .copyDescription = _MOMControllerCopyDescription_CFAllocatorContext
    
};

static void
handleTcpConnect(CFSocketRef socket,
                 CFSocketCallBackType type,
                 CFDataRef address,
                 const void *data,
                 void *info)
{
    MOMControllerRef controller = (MOMControllerRef)info;
    CFSocketNativeHandle *nativeSocketHandle;
    
    if (type != kCFSocketAcceptCallBack)
        return;
    
    nativeSocketHandle = malloc(sizeof(*nativeSocketHandle));
    if (nativeSocketHandle == NULL)
        return;
    
    *nativeSocketHandle = *((CFSocketNativeHandle *)data);
    
    _MOMResolveHostRestrictionAndPerform(controller, ^void (MOMControllerRef controller, CFArrayRef restrictAddressList) {
        uint8_t name[sizeof(struct sockaddr_storage)];
        char buffer[1024];
        socklen_t nameLen = sizeof(name);
        CFDataRef peerAddress = NULL;
        CFStringRef peerName = NULL;
        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        const struct sockaddr_in *sin;
        const int yes = 1;

        if (getpeername(*nativeSocketHandle, (struct sockaddr *)name, &nameLen) == 0) {
            peerAddress = CFDataCreate(kCFAllocatorDefault, name, nameLen);
        }
        
        if (peerAddress == NULL || ((struct sockaddr *)name)->sa_family != AF_INET) {
            close(*nativeSocketHandle);
            goto out;
        }
        
        sin = (const struct sockaddr_in *)name;
        if (inet_ntop(PF_INET, &sin->sin_addr, buffer, sizeof(buffer)) == NULL) {
            peerName = CFSTR("<unknown>");
        } else {
            peerName = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%s"), buffer);
        }

        if (restrictAddressList && !addressIsInList(peerAddress, restrictAddressList)) {
            _MOMDebugLog(CFSTR("rejected connection from %@"), peerName);
            close(*nativeSocketHandle);
            goto out;
        }
        
        if (setsockopt(*nativeSocketHandle, IPPROTO_TCP, TCP_NODELAY, (void *)&yes, sizeof(yes)) != 0) {
            int savedError = errno;
            
            _MOMDebugLog(CFSTR("failed to set TCP_NODELAY on socket for peer %@: %s"), peerName, strerror(savedError));
        }

        CFStreamCreatePairWithSocket(kCFAllocatorDefault,
                                     *nativeSocketHandle,
                                     &readStream,
                                     &writeStream);
        if (!_MOMHandleConnectionFromNewAddress(controller, peerAddress, peerName, readStream, writeStream)) {
            close(*nativeSocketHandle);
            goto out;
        }
 
    out:
        if (readStream)
            CFRelease(readStream);
        if (writeStream)
            CFRelease(writeStream);
        if (peerAddress)
            CFRelease(peerAddress);
        if (peerName)
            CFRelease(peerName);
        free(nativeSocketHandle);
    });
}

static CFSocketRef
createTcpListenerSocket(MOMControllerRef controller)
{
    const struct sockaddr_in *sinLocalAddress = _MOMGetLocalInterfaceAddress(controller);
    CFSocketContext socketContext = _MOMControllerSocketContext;
    CFSocketRef tcpSocket;
    struct sockaddr_in sin;
    CFDataRef sinData = NULL;
    const int yes = 1;
    
    socketContext.info = controller;
    
    tcpSocket = CFSocketCreate(kCFAllocatorDefault,
                               PF_INET,
                               SOCK_STREAM,
                               IPPROTO_TCP,
                               kCFSocketAcceptCallBack,
                               handleTcpConnect,
                               &socketContext);
    if (tcpSocket == NULL) {
        return NULL;
    }
    
    if (setsockopt(CFSocketGetNative(tcpSocket), SOL_SOCKET, SO_REUSEADDR, (void *)&yes, sizeof(yes)) != 0) {
        int savedError = errno;
        
        _MOMDebugLog(CFSTR("failed to set SO_REUSEADDR on socket: %s"), strerror(savedError));
    }
    
    memset(&sin, 0, sizeof(sin));
#ifdef __APPLE__
    sin.sin_len = sizeof(sin);
#endif
    sin.sin_family = AF_INET;
    sin.sin_port = htons(kMOMControlPort);
    sin.sin_addr.s_addr = sinLocalAddress ? sinLocalAddress->sin_addr.s_addr : INADDR_ANY;

    sinData = CFDataCreate(kCFAllocatorDefault, (uint8_t *)&sin, sizeof(sin));
    if (sinData == NULL) {
        CFSocketInvalidate(tcpSocket);
        CFRelease(tcpSocket);
        return NULL;
    }
    
    if (CFSocketSetAddress(tcpSocket, sinData) != kCFSocketSuccess) {
        CFSocketInvalidate(tcpSocket);
        CFRelease(tcpSocket);
        tcpSocket = NULL;
    }
    
    CFRelease(sinData);
    
    return tcpSocket;
}

static void
setDefaultOptionInt32(MOMControllerRef controller,
                      CFTypeRef option,
                      int32_t value)
{
    if (!CFDictionaryContainsKey(controller->options, option)) {
        CFNumberRef number;
        
        number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
        CFDictionarySetValue(controller->options, option, number);
        CFRelease(number);
    }
}

static void
setDefaultOptionString(MOMControllerRef controller,
                       CFStringRef option,
                       CFStringRef defaultOption)
{
    CFTypeRef value = CFDictionaryGetValue(controller->options, option);
    
    if (value == NULL ||
        CFGetTypeID(value) != CFStringGetTypeID() ||
        CFStringGetLength(value) == 0) {
        if (defaultOption) {
            CFDictionarySetValue(controller->options, option, defaultOption);
        } else {
            CFDictionaryRemoveValue(controller->options, option);
        }
    }
}

_Nullable
MOMControllerRef MOMControllerCreate(_Nullable CFAllocatorRef allocator,
                                     _Nullable CFDictionaryRef options,
                                     _Nullable CFRunLoopRef runloop,
                                     MOMStatus (^_Nonnull handler)(_Nonnull MOMControllerRef,
                                                                   MOMPeerContext *,
                                                                   MOMEvent,
                                                                   _Nonnull CFArrayRef,
                                                                   _Nullable MOMSendReplyCallback))
{
    struct _MOMController *controller;
    
    controller = (MOMControllerRef)calloc(1, sizeof(*controller));
    if (controller == NULL)
        return NULL;
 
    controller->retainCount = 1;
    
    if (options == NULL) {
        controller->options = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    } else {
        controller->options = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, options);
    }
    
    setDefaultOptionInt32(controller,   kMOMDeviceID,                   10);
    setDefaultOptionString(controller,  kMOMDeviceName,                 CFSTR("MOM"));
    setDefaultOptionString(controller,  kMOMModelID,                    CFSTR("710"));
    setDefaultOptionString(controller,  kMOMSerialNumber,               CFSTR("71000000000"));
    setDefaultOptionString(controller,  kMOMSystemTypeAndVersion,       CFSTR("710100A   171127"));
    setDefaultOptionString(controller,  kMOMCPUFirmwareTag,             CFSTR("cpufw"));
    setDefaultOptionString(controller,  kMOMCPUFirmwareVersion,         CFSTR("1.0.0.2"));
    setDefaultOptionString(controller,  kMOMRecoveryFirmwareTag,        CFSTR("recovery"));
    setDefaultOptionString(controller,  kMOMRecoveryFirmwareVersion,    CFSTR("1.0.0.2"));
    setDefaultOptionString(controller,  kMOMRestrictToSpecifiedHost,    NULL);
    
    controller->handler = _Block_copy(handler);
    controller->runLoop = runloop ? runloop : CFRunLoopGetCurrent();
    CFRetain(controller->runLoop);
    controller->peers = _MOMCreatePeerContextArray(1);
    
    _MOMSetAliveTime(controller, kMOMDefaultAliveTime);
    
    return controller;
}

void
MOMControllerRelease(MOMControllerRef controller)
{
    __MOMControllerReleaseStrong(controller);
}

MOMControllerRef
MOMControllerRetain(MOMControllerRef controller)
{
    return __MOMControllerRetainStrong(controller);
}

static MOMStatus
enqueueEvent(MOMControllerRef controller,
             MOMEvent event,
             CFArrayRef eventParams)
{
    CFIndex i;
    CFDataRef message;
    
    if (CFArrayGetCount(controller->peers) == 0)
        return kMOMStatusSocketError;
    
    message = _MOMCreateMessageFromEvent(event, eventParams);
    if (message == NULL)
        return kMOMStatusNoMemory;
    
    for (i = 0; i < CFArrayGetCount(controller->peers); i++) {
        MOMPeerContext *peerContext = (MOMPeerContext *)CFArrayGetValueAtIndex(controller->peers, i);
        
        _MOMControllerEnqueueMessage(controller, peerContext, message);
    }
    
    CFRelease(message);
    
    return kMOMStatusSuccess;
}

MOMStatus
_MOMControllerEnqueueNotification(MOMControllerRef controller,
                                  MOMEvent event,
                                  CFArrayRef eventParams)
{
    return enqueueEvent(controller, event | kMOMEventTypeDeviceNotification, eventParams);
}

MOMStatus
MOMControllerNotify(MOMControllerRef controller,
                    MOMEvent event,
                    CFArrayRef eventParams)
{
    MOMStatus status;

    status = _MOMControllerEnqueueNotification(controller, event, eventParams);
    if (status == kMOMStatusSuccess) {
        status = _MOMControllerSendToPeers(controller);
    }

    return status;
}

MOMStatus
MOMControllerNotifyDeferred(MOMControllerRef controller,
                            MOMEvent event,
                            CFArrayRef eventParams)
{
    return _MOMControllerEnqueueNotification(controller, event, eventParams);
}

MOMStatus
MOMControllerSendDeferred(MOMControllerRef controller)
{
    return _MOMControllerSendToPeers(controller);
}

CFMutableDictionaryRef
MOMControllerGetOptions(MOMControllerRef controller)
{
    return controller->options;
}

MOMStatus
MOMControllerBeginDiscoverability(MOMControllerRef controller)
{
    CFRunLoopSourceRef socketSource;
    CFSocketRef tcpSocket = NULL, udpSocket = NULL;
    MOMStatus status = kMOMStatusSocketError;
    
    if (controller->tcpSocket != NULL || controller->udpSocket != NULL)
        return kMOMStatusInvalidParameter;
    
    tcpSocket = createTcpListenerSocket(controller);
    if (tcpSocket == NULL)
        goto out;
    
    socketSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, tcpSocket, 0);
    CFRunLoopAddSource(controller->runLoop, socketSource, kCFRunLoopCommonModes);
    CFRelease(socketSource);
    
    udpSocket = _MOMCreateDiscoverySocket(controller);
    if (udpSocket == NULL)
        goto out;
    
    socketSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, udpSocket, 0);
    CFRunLoopAddSource(controller->runLoop, socketSource, kCFRunLoopCommonModes);
    CFRelease(socketSource);
    
    controller->tcpSocket = tcpSocket;
    controller->udpSocket = udpSocket;
    status = MOMControllerAnnounceDiscoverability(controller);
    
out:
    if (status != kMOMStatusSuccess) {
        if (tcpSocket) {
            CFSocketInvalidate(tcpSocket);
            CFRelease(tcpSocket);
        }
        if (udpSocket) {
            CFSocketInvalidate(udpSocket);
            CFRelease(udpSocket);
        }
    }
    
    return status;
}

MOMStatus
MOMControllerEndDiscoverability(MOMControllerRef controller)
{
    if (controller->tcpSocket) {
        CFSocketInvalidate(controller->tcpSocket);
        CFRelease(controller->tcpSocket);
        controller->tcpSocket = NULL;
    }
    
    if (controller->udpSocket) {
        CFSocketInvalidate(controller->udpSocket);
        CFRelease(controller->udpSocket);
        controller->udpSocket = NULL;
    }

    _MOMSetMasterPeer(controller, NULL);
    _MOMInvalidatePeers(controller);

    return kMOMStatusSuccess;
}

const struct sockaddr_in *
_MOMGetLocalInterfaceAddress(MOMControllerRef controller)
{
    CFDataRef sinLocalAddress = CFDictionaryGetValue(controller->options, kMOMLocalInterfaceAddress);
    if (sinLocalAddress == NULL)
        return NULL;
    
    const struct sockaddr *sa = (const struct sockaddr *)CFDataGetBytePtr(sinLocalAddress);
    if (sa->sa_family != AF_INET)
        return NULL;
    
    return (const struct sockaddr_in *)sa;
}
