//
//  SurrogateStateMachine.c
//  Surrogate
//
//  Created by Luke Howard on 15.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#include "SurrogateInternal.h"
#include "SurrogateHelpers.h"

/*
 * A note on writing handlers: the parameter list is treated as a stack. By default all
 * parameters from the request are echoed back to the host (if the host expects a reply).
 *
 * The returned status is inserted at top of the stack (index 0): this need not be done
 * by the handler.
 *
 * Return values should be pushed in reverse order onto the stack.
 *
 * If a request parameter is not needed, it should be popped, otherwise it can be left;
 * usually they are echoed back to the host.
 */

// HostRequest
static MOMStatus
aliveRequest(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
getDeviceID(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    insertOption(params, controller, kMOMDeviceName);
    insertOption(params, controller, kMOMDeviceID);

    return kMOMStatusSuccess;
}

// HostNotification
static MOMStatus
setDeviceID(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    int32_t deviceID = 0;
    CFNumberRef deviceIDNumber = NULL;
    CFStringRef deviceName = NULL;
    
    if (!getNumberAt(params, 0, &deviceID))
        return kMOMStatusInvalidRequest;

    if (deviceID < 1)
        return kMOMStatusInvalidParameter;
    
    deviceName = getStringAt(params, 1);
    if (deviceName == NULL)
        return kMOMStatusInvalidRequest;
   
    deviceIDNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &deviceID);
    CFDictionarySetValue(controller->options, kMOMDeviceID, deviceIDNumber);
    CFRelease(deviceIDNumber);

    CFDictionarySetValue(controller->options, kMOMDeviceName, deviceName);
    CFRelease(deviceName);
 
    return kMOMStatusContinue; // allow application handler to run too
}

// HostRequest
static MOMStatus
getHardwareConfig(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    int32_t version = 0;
   
    if (!getNumberAt(params, 0, &version))
        return kMOMStatusInvalidRequest;

    if (version != 2)
        return kMOMStatusInvalidParameter;
    
    insertOptionAt(params, 1, controller, kMOMSerialNumber);
    insertOptionAt(params, 1, controller, kMOMSystemTypeAndVersion);
    insertNumberAt(params, 1, 1);

    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
getSoftwareVersion(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    int32_t version;

    if (!getNumberAt(params, 0, &version))
        return kMOMStatusInvalidRequest;

    if (version != 2)
        return kMOMStatusInvalidParameter;

    insertOptionAt(params, 1, controller, kMOMRecoveryFirmwareVersion);
    insertOptionAt(params, 1, controller, kMOMRecoveryFirmwareTag);
    insertOptionAt(params, 1, controller, kMOMCPUFirmwareVersion);
    insertOptionAt(params, 1, controller, kMOMCPUFirmwareTag);
    
    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
getDeviceInfo(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    insertOption(params, controller, kMOMSerialNumber);
    insertNumber(params, 0);
    insertOption(params, controller, kMOMModelID);
    
    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
getMaster(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    insertNumber(params, !!_MOMPeerIsMaster(controller, peerContext));
    
    return kMOMStatusSuccess;
}

// HostNotification
static MOMStatus
setMaster(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    int32_t master;
    
    if (!getNumberAt(params, 0, &master))
        return kMOMStatusInvalidRequest;

    _MOMSetMasterPeer(controller, master ? peerContext : NULL);
    _MOMSetPeerPortStatus(controller, peerContext, master ? kMOMPortStatusConnected : kMOMPortStatusReady, NULL);
 
    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
getAliveTime(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    insertNumber(params, controller->aliveTime);
    
    return kMOMStatusSuccess;
}

// HostNotification
static MOMStatus
setAliveTime(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    int32_t aliveTime = 0;
    
    if (!getNumberAt(params, 0, &aliveTime))
        return kMOMStatusInvalidRequest;

    if (!_MOMSetAliveTime(controller, aliveTime))
        return kMOMStatusInvalidParameter;

    // this is the last thing DADman sends before marking unit as ready
    if (_MOMGetPeerPortStatus(controller, peerContext) < kMOMPortStatusReady)
        _MOMSetPeerPortStatus(controller, peerContext, kMOMPortStatusReady, NULL);

    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
getIPAddress(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    insertString(params, CFSTR("")); // MAC address
    insertString(params, CFSTR("")); // router
    insertString(params, CFSTR("")); // mask
    insertString(params, CFSTR("")); // IP address
    insertNumber(params, 1); // DHCP
    
    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
setIPAddress(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    return kMOMStatusContinue;
}

// HostRequest
static MOMStatus
getKeyMode(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    int32_t keyNumber;

    if (!getNumberAt(params, 0, &keyNumber))
        return kMOMStatusInvalidRequest;

    if (keyNumber < kMOMKeyIDOutput1 || keyNumber > kMOMKeyIDExternal)
        return kMOMStatusInvalidParameter;

    insertNumberAt(params, 1, 0);
    insertNumberAt(params, 1, 1);
    
    return kMOMStatusSuccess;
}

// HostRequest
static MOMStatus
setKeyMode(MOMControllerRef controller, MOMPeerContext *peerContext, MOMEvent event, CFMutableArrayRef params)
{
    int32_t keyNumber;
    int32_t keyMode;
    int32_t keyUnknown; // seems to be ignored?
    
    if (!getNumberAt(params, 0, &keyNumber) ||
        !getNumberAt(params, 1, &keyMode) ||
        !getNumberAt(params, 2, &keyUnknown))
        return kMOMStatusInvalidRequest;
    
    if (keyNumber < kMOMKeyIDOutput1 || keyNumber > kMOMKeyIDExternal)
        return kMOMStatusInvalidParameter;
    
    if (keyMode != 1)
        return kMOMStatusInvalidParameter;
    
    return kMOMStatusSuccess;
}

typedef MOMStatus (*_MOMMessageHandler)(MOMControllerRef, MOMPeerContext *peerContext, MOMEvent, CFMutableArrayRef);

static struct {
    MOMEvent validTypes;
    _MOMMessageHandler handler;
} _MOMEventHandlers[kMOMEventMax + 1] = {
    [kMOMEventAliveRequest]         = { kMOMEventTypeHostGetRequest,        aliveRequest                },
    [kMOMEventIdentify]             = { kMOMEventTypeHostSetRequest,        NULL                        },
    [kMOMEventGetHardwareConfig]    = { kMOMEventTypeHostGetRequest,        getHardwareConfig           },
    [kMOMEventGetSoftwareVersion]   = { kMOMEventTypeHostGetRequest,        getSoftwareVersion          },
    [kMOMEventGetDeviceInfo]        = { kMOMEventTypeHostGetRequest,        getDeviceInfo               },
    [kMOMEventGetMaster]            = { kMOMEventTypeHostGetRequest,        getMaster                   },
    [kMOMEventSetMaster]            = { kMOMEventTypeHostNotification,      setMaster                   },
    [kMOMEventGetAliveTime]         = { kMOMEventTypeHostGetRequest,        getAliveTime                },
    [kMOMEventSetAliveTime]         = { kMOMEventTypeHostSetRequest,        setAliveTime                },
    [kMOMEventGetDeviceID]          = { kMOMEventTypeHostGetRequest,        getDeviceID                 },
    [kMOMEventSetDeviceID]          = { kMOMEventTypeHostNotification,      setDeviceID                 },
    [kMOMEventGetIPAddress]         = { kMOMEventTypeHostGetRequest,        getIPAddress                },
    [kMOMEventSetIPAddress]         = { kMOMEventTypeHostSetRequest,        setIPAddress                },
    [kMOMEventGetKeyMode]           = { kMOMEventTypeHostGetRequest,        getKeyMode                  },
    [kMOMEventSetKeyMode]           = { kMOMEventTypeHostSetRequest,        setKeyMode                  },
    [kMOMEventGetKeyState]          = { kMOMEventTypeHostGetRequest,        NULL                        },
    [kMOMEventGetLedState]          = { kMOMEventTypeHostGetRequest,        NULL                        },
    [kMOMEventSetLedState]          = { kMOMEventTypeHostNotification,      NULL                        },
    [kMOMEventGetLedIntensity]      = { kMOMEventTypeHostGetRequest,        NULL                        },
    [kMOMEventSetLedIntensity]      = { kMOMEventTypeHostNotification,      NULL                        },
    [kMOMEventGetRotationCount]     = { kMOMEventTypeHostGetRequest,        NULL                        },
    [kMOMEventSetRotationCount]     = { kMOMEventTypeHostNotification,      NULL                        },
    [kMOMEventGetRingLedState]      = { kMOMEventTypeHostGetRequest,        NULL                        },
    [kMOMEventSetRingLedState]      = { kMOMEventTypeHostNotification,      NULL                        },
};

static inline bool
isEventValidOnNonMaster(MOMEvent eventWithType)
{
    MOMEvent event = MOMEventGetEvent(eventWithType);
    
    return MOMEventIsHostRequest(eventWithType) || event < kMOMEventGetKeyMode;
}

static MOMStatus
sendReply(_Nonnull MOMControllerRef controller,
          struct _MOMPeerContext *_Nonnull peerContext,
          MOMEvent eventWithType,
          MOMStatus status,
          _Nonnull CFArrayRef eventParams)
{
    CFDataRef messageBuf;
    CFMutableArrayRef replyParams;

    replyParams = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, eventParams);
    if (replyParams == NULL) {
        status = kMOMStatusNoMemory;
        goto cleanup;
    }

    insertNumber(replyParams, (int32_t)status);

    /* we need to send something back to the host */
    messageBuf = _MOMCreateDeviceReplyMessage(eventWithType, replyParams);
    if (messageBuf) {
        if (MOMEventGetEvent(eventWithType) != kMOMEventAliveRequest) {
            _MOMDebugLog(CFSTR("queued message %.*s"),
                         (int)CFDataGetLength(messageBuf) - 1, (char *)CFDataGetBytePtr(messageBuf));
        }
        _MOMPeerContextRetain(peerContext);
        dispatch_async(dispatch_get_main_queue(), ^{
            _MOMControllerEnqueueMessage(controller, peerContext, messageBuf);
            _MOMPeerContextRelease(peerContext); /* matching +1 above */
            CFRelease(messageBuf);
        });
        status = kMOMStatusSuccess;
    } else {
        status = kMOMStatusNoMemory;
    }

    CFRelease(replyParams);

cleanup:
    _MOMPeerContextRelease(peerContext); /* matching +1 in _MOMProcessEvent() */

    return status;
}

MOMStatus
_MOMProcessEvent(MOMControllerRef controller,
                 MOMPeerContext *peerContext,
                 MOMEvent eventWithType,
                 CFArrayRef eventParams)
{
    CFMutableArrayRef replyParams;
    MOMEvent validTypes;
    MOMEvent event = MOMEventGetEvent(eventWithType);
    MOMEvent eventType = MOMEventGetType(eventWithType);
    MOMStatus status;
 
    /* Assert implementation sanity */
    assert(eventType & kMOMEventTypeHostAny);
    assert((eventType & kMOMEventTypeDeviceAny) == 0);
    assert(event > kMOMEventNone);
    assert(event <= kMOMEventMax);
    
    replyParams = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, eventParams);
    if (replyParams == NULL)
        return kMOMStatusNoMemory;

    /* Check that the event type matches the handler */
    validTypes = _MOMEventHandlers[event].validTypes;
    
    if (!_MOMPeerIsMaster(controller, peerContext) &&
        !isEventValidOnNonMaster(eventWithType)) {
        status = kMOMStatusRequiresMaster;
    } else if (eventType & validTypes) {
        _MOMMessageHandler handler = _MOMEventHandlers[event].handler;

        status = kMOMStatusContinue;

        if (handler) {
            status = handler(controller, peerContext, event, replyParams);
            if (status != kMOMStatusContinue && MOMEventIsHostRequest(eventWithType)) {
                _MOMPeerContextRetain(peerContext);
                status = sendReply(controller, peerContext, eventWithType, status, replyParams);
                /* this will always release peerContext */
                assert(status != kMOMStatusContinue);
            }
        }

        /* second chance handler */
        if (status == kMOMStatusContinue) {
            if (MOMEventIsHostRequest(eventWithType)) {
                _MOMPeerContextRetain(peerContext);
                status = controller->handler(controller, peerContext, eventWithType, replyParams, sendReply);
                /* handler must call sendReply(), which will release peerContext */
            } else {
                status = controller->handler(controller, peerContext, eventWithType, replyParams, NULL);
            }
        }
        if (status == kMOMStatusContinue)
            status = kMOMStatusInvalidRequest;
    } else {
        status = kMOMStatusInvalidRequest;
    }

    CFRelease(replyParams);

    return status;
}
