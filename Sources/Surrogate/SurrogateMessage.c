//
//  SurrogateMessage.c
//  Surrogate
//
//  Created by Luke Howard on 15.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#include "SurrogateInternal.h"

#define kMOMHostGetRequestTag           ((UniChar)'?')
#define kMOMHostSetRequestTag           ((UniChar)'&')
#define kMOMHostNotificationTag         ((UniChar)'%')
#define kMOMDeviceReplyTag              ((UniChar)':')
#define kMOMDeviceNotificationTag       ((UniChar)'!')

static MOMEvent
messageTagToEventType(UniChar messageTag)
{
    switch (messageTag) {
        case kMOMHostGetRequestTag:
            return kMOMEventTypeHostGetRequest;
        case kMOMHostSetRequestTag:
            return kMOMEventTypeHostSetRequest;
        case kMOMHostNotificationTag:
            return kMOMEventTypeHostNotification;
        case kMOMDeviceReplyTag:
            return kMOMEventTypeDeviceReply;
        case kMOMDeviceNotificationTag:
            return kMOMEventTypeDeviceNotification;
        default:
            break;
    }
    
    return kMOMEventNone;
}

static UniChar
eventToMessageTag(MOMEvent event)
{
    switch (MOMEventGetType(event)) {
        case kMOMEventTypeHostGetRequest:
            return kMOMHostGetRequestTag;
        case kMOMEventTypeHostSetRequest:
            return kMOMHostSetRequestTag;
        case kMOMEventTypeHostNotification:
            return kMOMHostNotificationTag;
        case kMOMEventTypeDeviceReply:
            return kMOMDeviceReplyTag;
        case kMOMEventTypeDeviceNotification:
            return kMOMDeviceNotificationTag;
        default:
            break;
    }

    return 0;
}

static CFStringRef
_MOMMessages[kMOMEventMax + 1] = {
    [kMOMEventEnumerateDevices]             = CFSTR("edev"),
    [kMOMEventAliveRequest]                 = CFSTR("aliverequest"),
    [kMOMEventIdentify]                     = CFSTR("sidentify"),

    [kMOMEventGetHardwareConfig]            = CFSTR("ghwconf"),
    [kMOMEventGetSoftwareVersion]           = CFSTR("gswver"),
    [kMOMEventGetDeviceInfo]                = CFSTR("gdevinfo"),

    [kMOMEventGetMaster]                    = CFSTR("gmaster"),
    [kMOMEventSetMaster]                    = CFSTR("smaster"),

    [kMOMEventGetAliveTime]                 = CFSTR("galivetime"),
    [kMOMEventSetAliveTime]                 = CFSTR("salivetime"),

    [kMOMEventGetDeviceID]                  = CFSTR("gdevid"),
    [kMOMEventSetDeviceID]                  = CFSTR("sdevid"),

    [kMOMEventGetIPAddress]                 = CFSTR("gip"),
    [kMOMEventSetIPAddress]                 = CFSTR("sip"),

    [kMOMEventGetKeyMode]                   = CFSTR("gkeymode"),
    [kMOMEventSetKeyMode]                   = CFSTR("skeymode"),

    [kMOMEventGetKeyState]                  = CFSTR("gkeystate"),
    [kMOMEventSetKeyState]                  = CFSTR("skeystate"),

    [kMOMEventGetLedState]                  = CFSTR("gledstate"),
    [kMOMEventSetLedState]                  = CFSTR("sledstate"),

    [kMOMEventGetLedIntensity]              = CFSTR("gledint"),
    [kMOMEventSetLedIntensity]              = CFSTR("sledint"),

    [kMOMEventGetRotationCount]             = CFSTR("grotcount"),
    [kMOMEventSetRotationCount]             = CFSTR("srotcount"),

    [kMOMEventGetRingLedState]              = CFSTR("gringledstate"),
    [kMOMEventSetRingLedState]              = CFSTR("sringledstate"),
};

static inline void
cfStringAppendCharacter(CFMutableStringRef string, UniChar c)
{
    CFStringAppendCharacters(string, &c, 1);
}

CFDataRef
_MOMCreateMessageFromEvent(MOMEvent event,
                           CFArrayRef eventParams)
{
    CFMutableStringRef messageBuf;

    assert(MOMEventGetEvent(event) > kMOMEventNone && MOMEventGetEvent(event) <= kMOMEventMax);
    assert(MOMEventIsDeviceReply(event) || MOMEventIsDeviceNotification(event));

    messageBuf = CFStringCreateMutable(kCFAllocatorDefault, 0);
    if (messageBuf == NULL)
        return NULL;
  
    /* event type tag */ 
    cfStringAppendCharacter(messageBuf, eventToMessageTag(event));

    /* event name */
    CFStringAppend(messageBuf, _MOMMessages[MOMEventGetEvent(event)]);
    
    if (eventParams) {
        CFIndex i;
        
        CFNumberFormatterRef numberFormatter = CFNumberFormatterCreate(kCFAllocatorDefault,
                                                                       CFLocaleGetSystem(),
                                                                       kCFNumberFormatterNoStyle);
        
        for (i = 0; i < CFArrayGetCount(eventParams); i++) {
            CFTypeRef element = CFArrayGetValueAtIndex(eventParams, i);
            
            cfStringAppendCharacter(messageBuf, ',');
            
            if (CFGetTypeID(element) == CFStringGetTypeID()) {
                cfStringAppendCharacter(messageBuf, '\'');
                CFStringAppend(messageBuf, (CFStringRef)element);
                cfStringAppendCharacter(messageBuf, '\'');
            } else if (CFGetTypeID(element) == CFNumberGetTypeID()) {
                CFStringRef numberString = CFNumberFormatterCreateStringWithNumber(kCFAllocatorDefault,
                                                                                   numberFormatter,
                                                                                   (CFNumberRef)element);
                CFStringAppend(messageBuf, numberString);
                CFRelease(numberString);
            } else if (CFGetTypeID(element) == CFBooleanGetTypeID()) {
                CFStringAppend(messageBuf, element == kCFBooleanTrue ? CFSTR("1") : CFSTR("0"));
            } else if (CFGetTypeID(element) == CFNullGetTypeID()) {
                // do nothing
            } else {
                assert("unknown CF type");
            }
        }
        
        CFRelease(numberFormatter);
    }
    
    cfStringAppendCharacter(messageBuf, '\r');
    
    CFDataRef message = CFStringCreateExternalRepresentation(kCFAllocatorDefault, messageBuf, kCFStringEncodingUTF8, 0);
    CFRelease(messageBuf);
    
    return message;
}

MOMStatus
_MOMParseMessageData(CFDataRef messageBuffer,
                     MOMEvent *pEvent,
                     CFMutableArrayRef *pEventParams,
                     CFDataRef *pErrorReply)
{
    CFStringRef string;
    MOMStatus status;
    
    *pEvent = kMOMEventNone;
    *pEventParams = NULL;
    *pErrorReply = NULL;
    
    string = CFStringCreateWithBytes(kCFAllocatorDefault,
                                     CFDataGetBytePtr(messageBuffer),
                                     CFDataGetLength(messageBuffer),
                                     kCFStringEncodingUTF8,
                                     true);
    if (string == NULL)
        return kMOMStatusNoMemory;
    
    status = _MOMParseMessageString(string, pEvent, pEventParams, pErrorReply);

    CFRelease(string);

    return status;
    
}

static MOMEvent
parseEventName(CFStringRef messageBuf)
{
    CFIndex i;

    // seems to be hard-coded
    if (CFStringGetLength(messageBuf) > 16)
        return kMOMEventNone;
    
    for (i = 0; i <= kMOMEventMax; i++) {
        if (_MOMMessages[i] &&
            CFStringCompare(messageBuf, _MOMMessages[i], 0) == kCFCompareEqualTo) {
            return i;
        }
    }
    
    return kMOMEventNone;
}

static UniChar getPrefixCharacter(CFStringRef string)
{
    return CFStringGetLength(string) ? CFStringGetCharacterAtIndex(string, 0) : 0;
}

static void
makeErrorReply(MOMEvent eventType, CFStringRef eventName, CFDataRef *pErrorReply)
{
    CFStringRef errorMessage;
    
    if (!MOMEventIsHostRequest(eventType))
        return;
    
    errorMessage = CFStringCreateWithFormat(kCFAllocatorDefault,
                                            NULL,
                                            CFSTR("%c%@,%d\r"),
                                            eventToMessageTag(eventType),
                                            eventName,
                                            (eventType == kMOMEventTypeHostGetRequest) ? 0 : 1);
    
    *pErrorReply = CFStringCreateExternalRepresentation(kCFAllocatorDefault, errorMessage, kCFStringEncodingUTF8, 0);
    
    CFRelease(errorMessage);
}

MOMStatus
_MOMParseMessageString(CFStringRef string,
                       MOMEvent *pEvent,
                       CFMutableArrayRef *pEventParams,
                       CFDataRef *pErrorReply)
{
    bool ret = false;
    CFIndex i = 0;
    CFMutableArrayRef eventParams = NULL;
    CFArrayRef tokens = NULL;
    CFStringRef token = NULL, eventName = NULL;
    CFNumberFormatterRef numberFormatter = NULL;
    MOMEvent eventType, event;
 
    *pEvent = kMOMEventNone;
    *pEventParams = NULL;
    *pErrorReply = NULL;
    
    tokens = CFStringCreateArrayBySeparatingStrings(kCFAllocatorDefault,
                                                    string,
                                                    CFSTR(","));
    if (tokens == NULL)
        goto out;
    
    token = (CFStringRef)CFArrayGetValueAtIndex(tokens, 0);

    eventType = messageTagToEventType(getPrefixCharacter(token));
    if (eventType == kMOMEventNone)
        goto out;
    
    eventName = CFStringCreateWithSubstring(kCFAllocatorDefault,
                                            token,
                                            CFRangeMake(1, CFStringGetLength(token) - 1));
    event = parseEventName(eventName);
    if (event == kMOMEventNone) {
        makeErrorReply(eventType, eventName, pErrorReply);
        goto out;
    }
 
    if (event != kMOMEventAliveRequest) 
        _MOMDebugLog(CFSTR("parsing message %@"), string);

    eventParams = CFArrayCreateMutable(kCFAllocatorSystemDefault,
                                       CFArrayGetCount(tokens) - 1,
                                       &kCFTypeArrayCallBacks);
    if (eventParams == NULL)
        goto out;
    
    numberFormatter = CFNumberFormatterCreate(kCFAllocatorDefault,
                                              CFLocaleGetSystem(),
                                              kCFNumberFormatterNoStyle);
    
    for (i = 1; i < CFArrayGetCount(tokens); i++) {
        CFStringRef element = CFArrayGetValueAtIndex(tokens, i);
        
        if (getPrefixCharacter(element) == '\'' &&
            CFStringGetCharacterAtIndex(element, CFStringGetLength(element) - 1) == '\'') {
            CFStringRef stringValue = CFStringCreateWithSubstring(kCFAllocatorDefault,
                                                                  element,
                                                                  CFRangeMake(1, CFStringGetLength(element) - 2));
            CFArrayAppendValue(eventParams, stringValue);
            CFRelease(stringValue);
        } else {
            CFNumberRef number;
            
            number = CFNumberFormatterCreateNumberFromString(kCFAllocatorDefault,
                                                             numberFormatter,
                                                             element,
                                                             NULL,
                                                             kCFNumberFormatterParseIntegersOnly);
            if (number == NULL)
                continue;
            
            CFArrayAppendValue(eventParams, number);
            CFRelease(number);
        }
    }
    
    CFRelease(numberFormatter);
   
    *pEvent = event | eventType; 
    *pEventParams = eventParams;
    eventParams = NULL;
    ret = true;
    
out:
    if (eventParams)
        CFRelease(eventParams);
    if (eventName)
        CFRelease(eventName);
    if (tokens)
        CFRelease(tokens);

    assert(ret == false || *pEvent != kMOMEventNone);
    
    return ret ? kMOMStatusSuccess : kMOMStatusInvalidRequest;
}

CFDataRef
_MOMCreateDeviceReplyMessage(MOMEvent event, CFArrayRef eventParams)
{
    MOMEvent requestEvent = MOMEventGetEvent(event);
    MOMEvent requestEventType = MOMEventGetType(event);
    MOMEvent replyEventType;

    switch (requestEventType) {
    case kMOMEventTypeHostGetRequest:
    case kMOMEventTypeHostSetRequest:
        replyEventType = kMOMEventTypeDeviceReply;
        break;
    case kMOMEventTypeHostNotification:
        replyEventType = kMOMEventTypeDeviceNotification;
        break;
    default:
        replyEventType = kMOMEventNone;
        break;
    }

    assert(replyEventType != kMOMEventNone);

    return _MOMCreateMessageFromEvent(requestEvent | replyEventType, eventParams);
}
