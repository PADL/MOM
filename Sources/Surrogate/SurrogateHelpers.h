//
//  SurrogateHelpers.h
//  Surrogate
//
//  Created by Luke Howard on 21.05.18.
//  Copyright © 2018 PADL Software Pty Ltd. All rights reserved.
//

#ifndef SurrogateHelpers_h
#define SurrogateHelpers_h

static inline void
insertNumberAt(CFMutableArrayRef array, CFIndex index, int32_t number)
{
    CFNumberRef numberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &number);
    CFArrayInsertValueAtIndex(array, index, numberRef);
    CFRelease(numberRef);
}

static inline void
insertNumber(CFMutableArrayRef array, int32_t number)
{
    insertNumberAt(array, 0, number);
}

static inline void
insertStringAt(CFMutableArrayRef array, CFIndex index, CFStringRef string)
{
    CFArrayInsertValueAtIndex(array, index, string);
}

static inline void
insertString(CFMutableArrayRef array, CFStringRef string)
{
    insertStringAt(array, 0, string);
}

static inline void
insertOptionAt(CFMutableArrayRef array, CFIndex index, MOMControllerRef controller, CFStringRef key)
{
    CFTypeRef value = CFDictionaryGetValue(controller->options, key);
    if (value == NULL)
        value = kCFNull;
    CFArrayInsertValueAtIndex(array, index, value);
}

static inline void
insertOption(CFMutableArrayRef array, MOMControllerRef controller, CFStringRef key)
{
    insertOptionAt(array, 0, controller, key);
}

static inline bool
getNumberAt(CFArrayRef array, CFIndex index, int32_t *pValue)
{
    CFIndex last = CFArrayGetCount(array);
    CFTypeRef value;
    
    if (index >= last)
        return false;
    
    value = CFArrayGetValueAtIndex(array, index);
    if (CFGetTypeID(value) != CFNumberGetTypeID())
        return false;
    
    return CFNumberGetValue(value, kCFNumberSInt32Type, pValue);
}

static inline CFStringRef
getStringAt(CFArrayRef array, CFIndex index)
{
    CFIndex last = CFArrayGetCount(array);
    CFTypeRef value;
    
    if (index >= last)
        return NULL;
    
    value = CFArrayGetValueAtIndex(array, index);
    if (CFGetTypeID(value) != CFStringGetTypeID())
        return NULL;
    
    CFRetain(value);
    
    return (CFStringRef)value;
}

static inline bool
addressIsInList(CFDataRef address, CFArrayRef addressList)
{
    CFIndex i;
    const struct sockaddr_in *sin1 = (const struct sockaddr_in *)CFDataGetBytePtr(address);
    bool bMatched = false;
    
    for (i = 0; i < CFArrayGetCount(addressList); i++) {
        const struct sockaddr_in *sin2 = (const struct sockaddr_in *)CFDataGetBytePtr(CFArrayGetValueAtIndex(addressList, i));
        
        if (sin2->sin_family == AF_INET &&
            memcmp(&sin1->sin_addr, &sin2->sin_addr, sizeof(struct in_addr)) == 0) {
            bMatched = true;
            break;
        }
    }
    
    return bMatched;
}

#endif /* SurrogateHelpers_h */
