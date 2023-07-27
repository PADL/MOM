//
//  SurrogateInternal.h
//  Surrogate
//
//  Created by Luke Howard on 15.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#ifndef SurrogateInternal_h
#define SurrogateInternal_h

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>

#include <Surrogate/Surrogate.h>

typedef CF_ENUM(uint16_t, MOMPortNumber) {
    kMOMDiscoveryRequestPort = 10002,
    kMOMControlPort = 10003,
    kMOMDiscoveryReplyPort = 10004
};

#define kMOMDefaultAliveTime       20

struct _MOMPeerContext;

struct _MOMController {
    atomic_intptr_t retainCount;
    _Nullable CFMutableDictionaryRef options;
    MOMStatus (^_Nullable handler)(_Nonnull MOMControllerRef controller,
                                   struct _MOMPeerContext * _Nonnull,
                                   MOMEvent event,
                                   _Nonnull CFMutableArrayRef params,
                                   _Nullable MOMSendReplyCallback sendReply);
    _Nullable CFRunLoopRef runLoop;
    _Nullable CFSocketRef tcpSocket;
    _Nullable CFSocketRef udpSocket;
    _Nullable CFRunLoopTimerRef peerExpiryTimer;
    _Nullable CFMutableArrayRef peers;
    struct _MOMPeerContext * _Nullable peerMaster;
    int32_t aliveTime;
};

typedef CF_ENUM(CFIndex, MOMPortStatus) {
    kMOMPortStatusClosed = -1,
    kMOMPortStatusOpen,
    kMOMPortStatusReady,
    kMOMPortStatusConnected
};

typedef struct _MOMPeerContext {
    atomic_intptr_t retainCount;
    _Nullable MOMControllerRef controller;
    _Nullable CFDataRef peerAddress;
    _Nullable CFStringRef peerName;
    _Nullable CFReadStreamRef readStream;
    _Nullable CFWriteStreamRef writeStream;
    _Nullable CFMutableStringRef readBuffer;
    _Nullable CFMutableDataRef writeBuffer;
    CFIndex bytesWritten;
    MOMPortStatus portStatus;
    time_t lastActivity;
} MOMPeerContext;

extern const CFSocketContext _MOMControllerSocketContext;

/* SurrogateController.c */
MOMStatus
_MOMControllerEnqueueNotification(_Nonnull MOMControllerRef controller,
                                  MOMEvent event,
                                  _Nullable CFArrayRef eventParams);

/* SurrogateDiscovery.c */
_Nullable CFSocketRef
_MOMCreateDiscoverySocket(_Nonnull MOMControllerRef controller);

/* SurrogateHandlers.c */
MOMStatus
_MOMProcessEvent(_Nonnull MOMControllerRef controller,
                 MOMPeerContext *_Nonnull peerContext,
                 MOMEvent event,
                 _Nonnull CFArrayRef eventParams);

/* SurrogateMessage.c */
_Nullable CFDataRef
_MOMCreateMessageFromEvent(MOMEvent event,
                           _Nonnull CFArrayRef eventParams);

_Nullable  CFDataRef
_MOMCreateDeviceReplyMessage(MOMEvent requestEvent,
                             _Nonnull CFArrayRef replyParams);

MOMStatus
_MOMParseMessageData(_Nonnull CFDataRef messageBuf,
                     MOMEvent *_Nonnull pEvent,
                     _Nonnull CFMutableArrayRef *_Nullable pEventParams,
                     _Nonnull CFDataRef *_Nullable pErrorReply);

MOMStatus
_MOMParseMessageString(_Nonnull CFStringRef messageBuf,
                       MOMEvent *_Nonnull pEvent,
                       _Nonnull CFMutableArrayRef *_Nullable pEventParams,
                       _Nonnull CFDataRef *_Nullable pErrorReply);

/* SurrogatePeerContext.c */
void
_MOMControllerEnqueueMessage(_Nonnull MOMControllerRef controller,
                             MOMPeerContext *_Nonnull peerContext,
                             _Nonnull CFDataRef messageBuf);

_Nullable CFMutableArrayRef
_MOMCreatePeerContextArray(CFIndex capacity);

MOMPortStatus
_MOMGetPeerPortStatus(_Nonnull MOMControllerRef controller,
                      MOMPeerContext *_Nonnull peerContext);

void
_MOMSetPeerPortStatus(_Nonnull MOMControllerRef controller,
                      MOMPeerContext *_Nonnull peerContext,
                      MOMPortStatus status,
                      _Nullable CFErrorRef err);

bool
_MOMPeerIsMaster(_Nonnull MOMControllerRef controller,
                 MOMPeerContext *_Nonnull peerContext);

void
_MOMSetMasterPeer(_Nonnull MOMControllerRef controller,
                  MOMPeerContext *_Nullable peerContext);

bool
_MOMSetAliveTime(_Nonnull MOMControllerRef controller,
                 int32_t aliveTime);

void
_MOMPeerContextRetain(MOMPeerContext *_Nonnull peerContext);

void
_MOMPeerContextRelease(MOMPeerContext *_Nonnull peerContext);

bool
_MOMHandleConnectionFromNewAddress(_Nonnull MOMControllerRef controller,
                                   _Nonnull CFDataRef address,
                                   _Nonnull CFStringRef peerName,
                                   _Nonnull CFReadStreamRef readStream,
                                   _Nonnull CFWriteStreamRef writeStream);

MOMStatus
_MOMControllerSendToPeers(_Nonnull MOMControllerRef controller);

void
_MOMInvalidatePeers(_Nonnull MOMControllerRef controller);

/* SurrogateLogging.c */
void
_MOMDebugLog(_Nonnull CFStringRef format, ...);

/* SurrogateResolver.c */

// no need to retain controller, but retain anything else withResolvedHost needs
void
_MOMResolveHostRestrictionAndPerform(_Nonnull MOMControllerRef controller,
                                     void (^_Nonnull withResolvedHost)(_Nonnull MOMControllerRef controller,
                                                                       _Nullable CFArrayRef restrictAddressList));

const struct sockaddr_in * _Nullable
_MOMGetLocalInterfaceAddress(_Nonnull MOMControllerRef controller);

//! Project version number for Surrogate.
extern double SurrogateVersionNumber;

//! Project version string for Surrogate.
extern const unsigned char SurrogateVersionString[];

#endif /* SurrogateInternal_h */
