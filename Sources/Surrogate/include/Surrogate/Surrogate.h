//
//  Surrogate.h
//  Surrogate
//
//  Created by Luke Howard on 15.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#ifndef Surrogate_h
#define Surrogate_h

#include <CoreFoundation/CoreFoundation.h>

struct _MOMController;
typedef struct _MOMController *MOMControllerRef;

typedef CF_CLOSED_ENUM(CFIndex, MOMStatus) {
    kMOMStatusSocketError = -3,
    kMOMStatusNoMemory = -2,
    kMOMStatusContinue = -1,
    kMOMStatusSuccess = 0,
    kMOMStatusInvalidRequest = 1,
    kMOMStatusInvalidParameter = 2,
    kMOMStatusRequiresMaster = 4
};

typedef CF_CLOSED_ENUM(CFIndex, MOMLedID) {
    kMOMLedIDOutput1 = 1,
    kMOMLedIDOutput2,
    kMOMLedIDOutput3,
    kMOMLedIDSourceA,
    kMOMLedIDSourceB,
    kMOMLedIDSourceC,
    kMOMLedIDRef,
    kMOMLedIDDim,
    kMOMLedIDTalk,
    kMOMLedIDCut,
    kMOMLedIDLayer
};

typedef CF_CLOSED_ENUM(CFIndex, MOMKeyID) {
    kMOMKeyIDOutput1 = 1,
    kMOMKeyIDOutput2,
    kMOMKeyIDOutput3,
    kMOMKeyIDSourceA,
    kMOMKeyIDSourceB,
    kMOMKeyIDSourceC,
    kMOMKeyIDRef,
    kMOMKeyIDDim,
    kMOMKeyIDTalk,
    kMOMKeyIDCut,
    kMOMKeyIDLayer,
    kMOMKeyIDExternal
};

typedef CF_CLOSED_ENUM(CFIndex, MOMLedIntensity) {
    kMOMLedIntensityLow = 1,
    kMOMLedIntensityNormal = 2,
    kMOMLedIntensityHigh = 3
};

typedef CF_ENUM(CFIndex, MOMEvent) {
    kMOMEventNone = 0,
    /* API events */
    kMOMEventPortError,
    kMOMEventPortClosed,
    kMOMEventPortOpen,
    kMOMEventPortReady,
    kMOMEventPortConnected,
    /* Discovery etc */
    kMOMEventEnumerateDevices,
    kMOMEventAliveRequest,
    kMOMEventIdentify,
    /* Device info */
    kMOMEventGetHardwareConfig,
    kMOMEventGetSoftwareVersion,
    kMOMEventGetDeviceInfo,
    /* Getters, setters */
    kMOMEventGetMaster,
    kMOMEventSetMaster,
    kMOMEventGetAliveTime,
    kMOMEventSetAliveTime,
    kMOMEventGetDeviceID,
    kMOMEventSetDeviceID,
    kMOMEventGetIPAddress,
    kMOMEventSetIPAddress,
    /* Getters, setters -- only valid on master */
    kMOMEventGetKeyMode,
    kMOMEventSetKeyMode,
    kMOMEventGetKeyState,
    kMOMEventSetKeyState,
    kMOMEventGetLedState,
    kMOMEventSetLedState, 
    kMOMEventGetLedIntensity,
    kMOMEventSetLedIntensity,
    kMOMEventGetRotationCount,
    kMOMEventSetRotationCount,
    kMOMEventGetRingLedState,
    kMOMEventSetRingLedState,
    kMOMEventMax                    = kMOMEventSetRingLedState,

    kMOMEventTypeHostGetRequest     = 0x01000000, // ? -- request from DADman (get)
    kMOMEventTypeHostSetRequest     = 0x02000000, // & -- request from DADman (set)
    kMOMEventTypeHostNotification   = 0x04000000, // % -- async notification from DADman
    kMOMEventTypeHostAny            = 0x0F000000,

    kMOMEventTypeDeviceReply        = 0x10000000, // : -- reply from MOM
    kMOMEventTypeDeviceNotification = 0x20000000, // ! -- async notification from MOM
    kMOMEventTypeDeviceAny          = 0xF0000000,

    kMOMEventTypeMask               = (kMOMEventTypeHostAny | kMOMEventTypeDeviceAny),
    kMOMEventMask                   = ~(kMOMEventTypeMask)
};

static inline MOMEvent
MOMEventGetType(MOMEvent event)
{
    return event & kMOMEventTypeMask;
}

static inline MOMEvent
MOMEventGetEvent(MOMEvent event)
{
    return event & kMOMEventMask;
}

static inline bool
MOMEventIsHostRequest(MOMEvent event)
{
    return MOMEventGetType(event) == kMOMEventTypeHostGetRequest ||
           MOMEventGetType(event) == kMOMEventTypeHostSetRequest;
}

static inline bool
MOMEventIsDeviceReply(MOMEvent event)
{
    return MOMEventGetType(event) == kMOMEventTypeDeviceReply;
}

static inline bool
MOMEventIsHostNotification(MOMEvent event)
{
    return MOMEventGetType(event) == kMOMEventTypeHostNotification;
}

static inline bool
MOMEventIsDeviceNotification(MOMEvent event)
{
    return MOMEventGetType(event) == kMOMEventTypeDeviceNotification;
}

extern _Nonnull const CFStringRef kMOMDeviceID;
extern _Nonnull const CFStringRef kMOMDeviceName;
extern _Nonnull const CFStringRef kMOMSerialNumber;
extern _Nonnull const CFStringRef kMOMModelID;
extern _Nonnull const CFStringRef kMOMSystemTypeAndVersion;
extern _Nonnull const CFStringRef kMOMCPUFirmwareTag;
extern _Nonnull const CFStringRef kMOMCPUFirmwareVersion;
extern _Nonnull const CFStringRef kMOMRecoveryFirmwareTag;
extern _Nonnull const CFStringRef kMOMRecoveryFirmwareVersion;
extern _Nonnull const CFStringRef kMOMRestrictToSpecifiedHost;
extern _Nonnull const CFStringRef kMOMLocalInterfaceAddress; // contains struct sockaddr as CFDataRef

_Nullable
MOMControllerRef MOMControllerCreate(_Nullable CFAllocatorRef allocator,
                                     _Nullable CFDictionaryRef options,
                                     _Nullable CFRunLoopRef runloop,
                                     MOMStatus (^_Nonnull handler)(_Nonnull MOMControllerRef,
                                                                   MOMEvent,
                                                                   _Nonnull CFMutableArrayRef));

_Nonnull CFMutableDictionaryRef
MOMControllerGetOptions(_Nonnull MOMControllerRef controller) CF_RETURNS_NOT_RETAINED;

MOMStatus
MOMControllerNotify(_Nonnull MOMControllerRef controller,
                    MOMEvent event,
                    _Nullable CFArrayRef eventParams);

MOMStatus
MOMControllerNotifyDeferred(_Nonnull MOMControllerRef controller,
                            MOMEvent event,
                            _Nullable CFArrayRef eventParams);

MOMStatus
MOMControllerSendDeferred(_Nonnull MOMControllerRef controller);

void MOMControllerRelease(_Nonnull MOMControllerRef controller);
_Nonnull MOMControllerRef MOMControllerRetain(_Nonnull MOMControllerRef controller);

MOMStatus
MOMControllerBeginDiscoverability(_Nonnull MOMControllerRef controller);

MOMStatus
MOMControllerEndDiscoverability(_Nonnull MOMControllerRef controller);

MOMStatus
MOMControllerAnnounceDiscoverability(_Nonnull MOMControllerRef controller);

MOMStatus
MOMEnumerateInterfaces(MOMStatus (^_Nonnull block)(const struct ifaddrs * _Nonnull));

#endif /* Surrogate_h */
