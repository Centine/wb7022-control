#include "uvc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

struct uvc_dev {
    IOUSBDeviceInterface650 **dev;
    uint8_t interface;
};

// Camera terminal, processing unit, Dell vendor XU and Microsoft XU, plus the
// 8-byte command (sel 1) and reply (sel 2) registers of XU 6. The rest of XU 6
// and all of XU 2 is firmware/debug space: reading XU 6 sel 8 resets the camera.
static int control_allowed(uint8_t unit, uint8_t selector, uint16_t len) {
    if (unit == 6) return (selector == 1 || selector == 2) && len == 8;
    return unit == 1 || unit == 3 || unit == 14 || unit == 15;
}

static void set_int(CFMutableDictionaryRef dict, CFStringRef key, int value) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &value);
    CFDictionarySetValue(dict, key, n);
    CFRelease(n);
}

uvc_dev *uvc_open(uint16_t vid, uint16_t pid, uint8_t vc_interface) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return NULL;
    set_int(match, CFSTR(kUSBVendorID), vid);
    set_int(match, CFSTR(kUSBProductID), pid);

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) return NULL;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plugin) return NULL;

    IOUSBDeviceInterface650 **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (hr != S_OK || !dev) return NULL;

    uvc_dev *u = calloc(1, sizeof *u);
    u->dev = dev;
    u->interface = vc_interface;
    return u;
}

void uvc_close(uvc_dev *u) {
    if (!u) return;
    (*u->dev)->Release(u->dev);
    free(u);
}

static int request(uvc_dev *u, uint8_t type, uint8_t code, uint8_t unit, uint8_t selector,
                   void *buf, uint16_t len) {
    if (!u || len == 0 || len > UVC_MAX_LEN) return -1;
    // GET_INFO and GET_LEN are harmless 1- and 2-byte queries.
    int meta = code == UVC_GET_INFO || code == UVC_GET_LEN;
    if (!control_allowed(unit, selector, len) && !(meta && control_allowed(unit, selector, 8))) return -1;
    IOUSBDevRequestTO r = {0};
    r.bmRequestType = type;
    r.bRequest = code;
    r.wValue = (uint16_t)selector << 8;
    r.wIndex = ((uint16_t)unit << 8) | u->interface;
    r.wLength = len;
    r.pData = buf;
    r.noDataTimeout = 500;
    r.completionTimeout = 500;
    kern_return_t kr = (*u->dev)->DeviceRequestTO(u->dev, &r);
    return kr == kIOReturnSuccess ? (int)r.wLenDone : -1;
}

int uvc_get(uvc_dev *u, uint8_t code, uint8_t unit, uint8_t selector, void *buf, uint16_t len) {
    if (code < UVC_GET_CUR || code > UVC_GET_DEF) return -1;
    // Class request, interface recipient, device-to-host.
    return request(u, 0xA1, code, unit, selector, buf, len);
}

int uvc_set(uvc_dev *u, uint8_t unit, uint8_t selector, const void *buf, uint16_t len) {
    return request(u, 0x21, UVC_SET_CUR, unit, selector, (void *)buf, len);
}
