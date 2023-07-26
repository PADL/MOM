//
//  SurrogateDiscovery.c
//  Surrogate
//
//  Created by Luke Howard on 15.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#include "SurrogateInternal.h"
#include "SurrogateHelpers.h"

static CFDataRef
createEnumerateDevicesMessage(MOMControllerRef controller, bool isSolicited)
{
    CFMutableArrayRef eventParams = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    MOMEvent event;
    CFDataRef messageBuf;
    
    //:edev,0,1,1,'DAD-MOM','710',0,'serialnumber'
    
    insertOption(eventParams, controller, kMOMSerialNumber);
    insertNumber(eventParams, 0);
    insertOption(eventParams, controller, kMOMModelID);
    insertOption(eventParams, controller, kMOMDeviceName);
    insertOption(eventParams, controller, kMOMDeviceID);
    insertNumber(eventParams, 1);
    insertNumber(eventParams, kMOMStatusSuccess);
    
    event = kMOMEventEnumerateDevices;
    if (isSolicited)
        event |= kMOMEventTypeDeviceReply;
    else
        event |= kMOMEventTypeDeviceNotification;
    
    messageBuf = _MOMCreateMessageFromEvent(event, eventParams);

    _MOMDebugLog(CFSTR("created discovery %s message %.*s"),
                 isSolicited ? "reply" : "notification",
                 (int)CFDataGetLength(messageBuf), CFDataGetBytePtr(messageBuf));
    
    CFRelease(eventParams);
    
    return messageBuf;
}

static void
debugDiscoveryReply(const struct sockaddr_in *sourceAddress,
                    const struct sockaddr_in *peerAddress,
                    const char *ifname,
                    bool isSolicited)
{
    char sourceAddressBuf[INET_ADDRSTRLEN] = "";
    char peerAddressBuf[INET_ADDRSTRLEN] = "";

    if (sourceAddress)
        inet_ntop(AF_INET, &sourceAddress->sin_addr, sourceAddressBuf, sizeof(sourceAddressBuf));
    inet_ntop(AF_INET, &peerAddress->sin_addr, peerAddressBuf, sizeof(peerAddressBuf));
    
    _MOMDebugLog(CFSTR("sending %s discovery %s message %s%s%sto %s:%d%s%s%s"),
                 peerAddress->sin_addr.s_addr == INADDR_BROADCAST ? "broadcast" : "unicast",
                 isSolicited ? "reply" : "notification",
                 sourceAddress ? "from " : "",
                 sourceAddress ? sourceAddressBuf : "",
                 sourceAddress ? " " : "",
                 peerAddressBuf, ntohs(peerAddress->sin_port),
                 ifname ? " (via " : "",
                 ifname ? ifname : "",
                 ifname ? ")" : "");
}

static CFSocketError
CFSocketSendDataWithPacketInfo(CFSocketRef s,
                               CFDataRef address,
                               CFDataRef data,
                               CFTimeInterval timeout,
                               CFDataRef pktInfoData)
{
    struct timeval tv;
    ssize_t size;
    struct iovec iov[1] = {{
        .iov_base = (void *)CFDataGetBytePtr(data),
        .iov_len = CFDataGetLength(data)
    }};
    union {
        uint8_t buffer[CMSG_SPACE(sizeof(struct in_pktinfo))];
        struct cmsghdr align;
    } msgControl;
    struct msghdr msg = {
        .msg_name = (void *)CFDataGetBytePtr(address),
        .msg_namelen = (socklen_t)CFDataGetLength(address),
        .msg_iov = iov,
        .msg_iovlen = sizeof(iov) / sizeof(iov[0]),
        .msg_control = NULL,
        .msg_controllen = 0,
        .msg_flags = 0
    };
    
    // borrowed from CFSocket.c
    tv.tv_sec = (timeout <= 0.0 || (CFTimeInterval)INT_MAX <= timeout) ? INT_MAX : (int)floor(timeout);
    tv.tv_usec = (int)floor(1.0e+6 * (timeout - floor(timeout)));

    if (pktInfoData) {
        struct cmsghdr *cmsg;
        
        msg.msg_control = msgControl.buffer;
        msg.msg_controllen = sizeof(msgControl.buffer);
        
        cmsg = CMSG_FIRSTHDR(&msg);

        assert(CMSG_SPACE(CFDataGetLength(pktInfoData)) <= sizeof(msgControl));
        
        cmsg->cmsg_level = IPPROTO_IP;
        cmsg->cmsg_type = IP_PKTINFO;
        cmsg->cmsg_len = CMSG_LEN((socklen_t)CFDataGetLength(pktInfoData));
        memcpy(CMSG_DATA(cmsg), CFDataGetBytePtr(pktInfoData), CFDataGetLength(pktInfoData));
        msg.msg_controllen = (socklen_t)CMSG_SPACE(CFDataGetLength(pktInfoData));
    }
    
    CFRetain(s);
    size = sendmsg(CFSocketGetNative(s), &msg, 0);
    CFRelease(s);
    
    return size > 0 ? kCFSocketSuccess : kCFSocketError;
}

static CFSocketError
sendDiscoveryReplyOnInterface(MOMControllerRef controller,
                              CFDataRef sourceAddress,
                              CFDataRef peerAddress,
                              CFDataRef pktInfoData,
                              const char *ifName,
                              bool isSolicited)
{
    CFDataRef message = NULL;
    CFSocketRef discoverySocket = NULL;
    CFRunLoopSourceRef socketSource = NULL;
    CFSocketContext socketContext = _MOMControllerSocketContext;
    CFSocketError socketError = kCFSocketError;
    CFDataRef sinPeerAddressData = NULL;
    struct sockaddr *saSourceAddress = sourceAddress ? (struct sockaddr *)CFDataGetBytePtr(sourceAddress) : NULL;
    struct sockaddr *saPeerAddress = peerAddress ? (struct sockaddr *)CFDataGetBytePtr(peerAddress) : NULL;
    int nativeSocketHandle;
            
    // currently IPv6 is not supported
    if ((saSourceAddress && saSourceAddress->sa_family != AF_INET) ||
        (saPeerAddress && saPeerAddress->sa_family != AF_INET))
        goto out;
        
    struct sockaddr_in sinPeerAddress = {
        .sin_len = sizeof(sinPeerAddress),
        .sin_family = AF_INET,
        .sin_port = htons(kMOMDiscoveryReplyPort),
        .sin_addr = { .s_addr = saPeerAddress ? ((struct sockaddr_in *)saPeerAddress)->sin_addr.s_addr : INADDR_BROADCAST },
        .sin_zero = {0}
    };
    sinPeerAddressData = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, (const uint8_t *)&sinPeerAddress, sizeof(sinPeerAddress), kCFAllocatorNull);
    if (sinPeerAddressData == NULL)
        goto out;
    
    socketContext.info = controller;
    discoverySocket = CFSocketCreate(kCFAllocatorDefault,
                                     PF_INET,
                                     SOCK_DGRAM,
                                     IPPROTO_UDP,
                                     kCFSocketDataCallBack,
                                     NULL,
                                     &socketContext);
    
    socketSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, discoverySocket, 0);
    CFRunLoopAddSource(controller->runLoop, socketSource, kCFRunLoopCommonModes);
    
    nativeSocketHandle = CFSocketGetNative(discoverySocket);
    
    debugDiscoveryReply((const struct sockaddr_in *)saSourceAddress, &sinPeerAddress, ifName, isSolicited);

    if (saSourceAddress) {
        struct in_pktinfo pktInfo = {
            .ipi_ifindex = 0,
            .ipi_spec_dst = ((const struct sockaddr_in *)saSourceAddress)->sin_addr,
            .ipi_addr = sinPeerAddress.sin_addr
        };
       
        /*
         * We need to bind the socket as implicit binding does not work when setting a
         * source address via in_pktinfo.ipi_spec_dst - sendmsg() returns EINVAL. The
         * only way to get this to work with an unbound socket is if an interface is
         * selected with ipi_ifindex.
         *
         * Note according to the public CoreFoundation source, CFSocketSetAddress()
         * will attempt to listen() on the socket but will ignore it failing.
         */
        if (CFSocketSetAddress(discoverySocket, sourceAddress) != kCFSocketSuccess) {
            int savedError = errno;

            _MOMDebugLog(CFSTR("failed to bind socket: %s"), strerror(savedError));
            goto out;
        }
        
        assert(pktInfoData == NULL);

        pktInfoData = CFDataCreate(kCFAllocatorDefault, (const uint8_t *)&pktInfo, sizeof(pktInfo));
        if (pktInfoData == NULL) {
            goto out;
        }
    }
        
    if (saPeerAddress == NULL) {
        const int yes = 1;
        
        if (setsockopt(nativeSocketHandle, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes)) != 0) {
            int savedError = errno;
            
            _MOMDebugLog(CFSTR("failed to set SO_BROADCAST on socket: %s"), strerror(savedError));
            goto out;
        }
    }
    
    message = createEnumerateDevicesMessage(controller, isSolicited);

    socketError = CFSocketSendDataWithPacketInfo(discoverySocket,
                                                 sinPeerAddressData,
                                                 message,
                                                 0,
                                                 pktInfoData);
    
    if (socketError != kCFSocketSuccess) {
        int savedError = errno;

        _MOMDebugLog(CFSTR("failed to send data with packet info: %s"), strerror(savedError));
    }
 
    CFRunLoopRemoveSource(controller->runLoop, socketSource, kCFRunLoopCommonModes);

out:
    if (saSourceAddress && pktInfoData)
        CFRelease(pktInfoData);
    if (message)
        CFRelease(message);
    if (socketSource)
        CFRelease(socketSource);
    if (discoverySocket) {
        CFSocketInvalidate(discoverySocket);
        CFRelease(discoverySocket);
    }
    if (sinPeerAddressData)
        CFRelease(sinPeerAddressData);
    
    return socketError;
}

MOMStatus
MOMEnumerateInterfaces(MOMStatus (^_Nonnull block)(const struct ifaddrs * _Nonnull))
{
    MOMStatus status = kMOMStatusSocketError;
    struct ifaddrs *interfaces, *ifp;

    if (getifaddrs(&interfaces) != 0) {
        int savedError = errno;

        _MOMDebugLog(CFSTR("failed to enumerate network interfaces: %s"), strerror(savedError));
        return kMOMStatusSocketError;
    }

    for (ifp = interfaces; ifp != NULL; ifp = ifp->ifa_next) {
        if (ifp->ifa_addr->sa_family != AF_INET)
            continue;

        if ((ifp->ifa_flags & (IFF_UP | IFF_RUNNING)) == 0)
            continue;

#if !TARGET_OS_SIMULATOR
        if (ifp->ifa_flags & IFF_LOOPBACK)
            continue;
#endif

#if TARGET_OS_IPHONE
        if (strncmp(ifp->ifa_name, "pdp_", 4) == 0)
            continue;
#endif
        
        MOMStatus blockStatus = block(ifp);
        if (blockStatus == kMOMStatusContinue)
            continue;
        
        status = blockStatus;
        if (blockStatus != kMOMStatusSuccess)
            break;
    }
    
    freeifaddrs(interfaces);

    return status;
}

static CFSocketError
sendDiscoveryReplyToAddress(MOMControllerRef controller,
                            CFDataRef peerAddress,
                            CFDataRef requestPktInfoData,
                            bool isSolicited)
{
    CFDataRef localInterfaceAddress = CFDictionaryGetValue(controller->options, kMOMLocalInterfaceAddress);
    CFSocketError socketError;
    
    /*
     * Enumerate up and running IPv4 addresses if we have a specific source
     * address, or if we are broadcasting (peerAddress == NULL). Otherwise,
     * shortcut is to use the supplied peerAddress and any source information
     * from the request.
     */
    if (localInterfaceAddress || peerAddress == NULL) {
        struct in_pktinfo *requestPktInfo =
            requestPktInfoData ? (struct in_pktinfo *)CFDataGetBytePtr(requestPktInfoData) : NULL;
        MOMStatus status;
        
        status = MOMEnumerateInterfaces(^ MOMStatus(const struct ifaddrs *ifp) {
            CFDataRef sourceAddress;
                        
            if (requestPktInfo) {
                assert(ifp->ifa_addr->sa_family == AF_INET);
                const struct sockaddr_in *sinLocalInterfaceAddress = (const struct sockaddr_in *)ifp->ifa_addr;
                
                if (requestPktInfo->ipi_ifindex != if_nametoindex(ifp->ifa_name) ||
                    requestPktInfo->ipi_spec_dst.s_addr != sinLocalInterfaceAddress->sin_addr.s_addr) {
#if DEBUG
                    char localInterfaceAddressBuffer[INET_ADDRSTRLEN] = "";
                    char requestPktInfoDstAddressBuffer[INET_ADDRSTRLEN] = "";
                    
                    inet_ntop(AF_INET, &sinLocalInterfaceAddress->sin_addr, localInterfaceAddressBuffer, sizeof(localInterfaceAddressBuffer));
                    inet_ntop(AF_INET, &requestPktInfo->ipi_spec_dst, requestPktInfoDstAddressBuffer, sizeof(requestPktInfoDstAddressBuffer));
                    _MOMDebugLog(CFSTR("interface %s[%s] differs from request destination address %s; ignoring"),
                                 ifp->ifa_name, localInterfaceAddressBuffer, requestPktInfoDstAddressBuffer);
#endif
                    return kMOMStatusContinue;
                }
            }

            sourceAddress = CFDataCreate(kCFAllocatorDefault, (const uint8_t *)ifp->ifa_addr, sizeof(*(ifp->ifa_addr)));
            if (sourceAddress == NULL) {
                return kMOMStatusNoMemory;
            } else if (localInterfaceAddress && CFEqual(localInterfaceAddress, sourceAddress) == false) {
                CFRelease(sourceAddress);
                return kMOMStatusContinue;
            }
                
            CFSocketError localError = sendDiscoveryReplyOnInterface(controller, sourceAddress, peerAddress, NULL, ifp->ifa_name, isSolicited);
            CFRelease(sourceAddress);
            return localError == kCFSocketSuccess ? kMOMStatusSuccess : kMOMStatusSocketError;
        });
        socketError = (status == kMOMStatusSuccess) ? kCFSocketSuccess : kCFSocketError;
    } else {
        socketError = sendDiscoveryReplyOnInterface(controller, NULL, peerAddress,
                                                    requestPktInfoData, NULL, isSolicited);
    }
   
    return socketError;
}

MOMStatus
MOMControllerAnnounceDiscoverability(MOMControllerRef controller)
{
    if (controller->tcpSocket == NULL || controller->udpSocket == NULL)
        return kMOMStatusInvalidParameter;

    _MOMResolveHostRestrictionAndPerform(controller, ^(MOMControllerRef controller, CFArrayRef addressList) {
        if (addressList) {
            CFIndex i;
        
            for (i = 0; i < CFArrayGetCount(addressList); i++)
                sendDiscoveryReplyToAddress(controller, CFArrayGetValueAtIndex(addressList, i), NULL, false);
        } else {
            sendDiscoveryReplyToAddress(controller, NULL, NULL, false);
        }
    });

    return kMOMStatusSuccess;
}

static const uint8_t
_MOMEchoString[] = { '\n', 0, 'N', 'T', 'P', ' ', 'E', 'c', 'h', 'o' };

static bool
isEchoRequest(CFDataRef echoRequest)
{
    return CFDataGetLength(echoRequest) >= sizeof(_MOMEchoString) &&
           memcmp(CFDataGetBytePtr(echoRequest), _MOMEchoString, sizeof(_MOMEchoString)) == 0;
}

static const uint8_t
_MOMDiscoveryString[] = { '?', 'e', 'd', 'e', 'v', '\r' };

static bool
isDiscoveryRequest(CFDataRef echoRequest)
{
    return CFDataGetLength(echoRequest) >= sizeof(_MOMDiscoveryString) &&
           memcmp(CFDataGetBytePtr(echoRequest), _MOMDiscoveryString, sizeof(_MOMDiscoveryString)) == 0;
}

static void
sendDiscoveryReply(MOMControllerRef controller, CFDataRef pktInfoData)
{
    const struct in_pktinfo *pktInfo = (const struct in_pktinfo *)CFDataGetBytePtr(pktInfoData);
    const struct sockaddr_in *sinLocalAddress =_MOMGetLocalInterfaceAddress(controller);
    const struct sockaddr_in sinPeerAddress = {
        .sin_len = sizeof(sinPeerAddress),
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr = pktInfo->ipi_addr,
        .sin_zero = {0}
    };
    
    if (sinLocalAddress &&
        sinLocalAddress->sin_addr.s_addr != pktInfo->ipi_spec_dst.s_addr) {
        return;
    }

    CFDataRef peerAddress = CFDataCreate(kCFAllocatorDefault, (uint8_t *)&sinPeerAddress, sinPeerAddress.sin_len);

    _MOMResolveHostRestrictionAndPerform(controller, ^(MOMControllerRef controller, CFArrayRef restrictAddressList) {
        /*
         * If a restrict host is specified, then send a unicast reply only if the request
         * came from an address associated with that host; otherwise, the request is dropped.
         *
         * If no restrict host is specified, then broadcast replies are sent, consistent with
         * the hardware MOM (even though this isn't strictly necessary).
         */
        CFDataRef replyAddress = restrictAddressList ? peerAddress : NULL;
        if (restrictAddressList == NULL || addressIsInList(peerAddress, restrictAddressList)) {
            sendDiscoveryReplyToAddress(controller, replyAddress, pktInfoData, true);
        } else {
            char buffer[INET_ADDRSTRLEN] = "";
            inet_ntop(AF_INET, &pktInfo->ipi_addr, buffer, sizeof(buffer));
            _MOMDebugLog(CFSTR("ignoring discovery request message from %s"), buffer);
        }
        CFRelease(peerAddress);
    });
}

static void
handleUdpPacket(CFSocketRef s,
                CFSocketCallBackType type,
                CFDataRef address,
                const void *data,
                void *info)
{
    MOMControllerRef controller = (MOMControllerRef)info;
    CFDataRef request = NULL, pktInfoData = NULL;
    struct sockaddr_in sin;
    uint8_t msgControl[1024], udpPacket[256];
    struct iovec iov[1] = { {
        .iov_base = udpPacket,
        .iov_len = sizeof(udpPacket)
    }};
    struct msghdr msg = {
        .msg_name = &sin,
        .msg_namelen = sizeof(sin),
        .msg_iov = iov,
        .msg_iovlen = sizeof(iov) / sizeof(iov[0]),
        .msg_control = msgControl,
        .msg_controllen = sizeof(msgControl),
        .msg_flags = 0
    };
    ssize_t len;
    struct cmsghdr *cmsg;

    if (type != kCFSocketReadCallBack)
        return;

    len = recvmsg(CFSocketGetNative(s), &msg, MSG_WAITALL);
    if (len < 0)
        return;
    
    for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == IPPROTO_IP && cmsg->cmsg_type == IP_PKTINFO) {
            struct in_pktinfo *pktInfo = (struct in_pktinfo *)CMSG_DATA(cmsg);
            
            /* preserve received address, because we may still send a broadcast packet */
            if (pktInfo->ipi_spec_dst.s_addr == 0)
                pktInfo->ipi_spec_dst.s_addr = sin.sin_addr.s_addr;
            
            pktInfoData = CFDataCreate(kCFAllocatorDefault, CMSG_DATA(cmsg), sizeof(struct in_pktinfo));
            break;
        }
    }
    
    request = CFDataCreate(kCFAllocatorDefault, udpPacket, len);
    
    if (pktInfoData == NULL || request == NULL)
        goto out;
    
    if (isEchoRequest(request)) {
        CFDataRef peerAddress = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, (uint8_t *)&sin, sin.sin_len, kCFAllocatorNull);
        CFSocketSendDataWithPacketInfo(s, peerAddress, request, 0, pktInfoData);
        CFRelease(peerAddress);
    } else if (isDiscoveryRequest(request)) {
        sendDiscoveryReply(controller, pktInfoData);
    }

out:
    if (request)
        CFRelease(request);
    if (pktInfoData)
        CFRelease(pktInfoData);
}

CFSocketRef
_MOMCreateDiscoverySocket(MOMControllerRef controller)
{
    CFSocketContext socketContext = _MOMControllerSocketContext;
    CFSocketRef socket;
    struct sockaddr_in sin;
    int nativeSocketHandle, yes = 1;

    socketContext.info = controller;
    
    socket = CFSocketCreate(kCFAllocatorDefault,
                            PF_INET,
                            SOCK_DGRAM,
                            IPPROTO_UDP,
                            kCFSocketReadCallBack,
                            handleUdpPacket,
                            &socketContext);
    if (socket == NULL)
        return NULL;
    
    memset(&sin, 0, sizeof(sin));
    sin.sin_len = sizeof(sin);
    sin.sin_family = AF_INET;
    sin.sin_port = htons(kMOMDiscoveryRequestPort);
    sin.sin_addr.s_addr = INADDR_ANY;

    nativeSocketHandle = CFSocketGetNative(socket);
    
    if (setsockopt(nativeSocketHandle, IPPROTO_IP, IP_PKTINFO, &yes, sizeof(yes)) != 0 ||
        setsockopt(nativeSocketHandle, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes)) != 0 ||
        bind(nativeSocketHandle, (struct sockaddr *)&sin, sizeof(sin)) != 0) {
        int savedError = errno;
        
        _MOMDebugLog(CFSTR("failed to bind discovery socket: %s"), strerror(savedError));
        CFSocketInvalidate(socket);
        CFRelease(socket);
        return NULL;
    }
    
    return socket;
}
