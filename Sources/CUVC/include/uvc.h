#ifndef UVC_H
#define UVC_H

#include <stdint.h>

/// Largest control payload we will ever transfer. The WB7022 has vendor
/// units with 512-byte debug buffers; reading one resets the camera.
#define UVC_MAX_LEN 64

/// UVC class-specific request codes (UVC 1.1, table A-8).
enum {
    UVC_SET_CUR = 0x01,
    UVC_GET_CUR = 0x81,
    UVC_GET_MIN = 0x82,
    UVC_GET_MAX = 0x83,
    UVC_GET_RES = 0x84,
    UVC_GET_LEN = 0x85,
    UVC_GET_INFO = 0x86,
    UVC_GET_DEF = 0x87,
};

typedef struct uvc_dev uvc_dev;

/// Opens the first USB device matching vid/pid for control transfers on EP0.
/// Does not take exclusive ownership, so it coexists with the system camera
/// driver and any app currently streaming. Returns NULL if not present.
uvc_dev *uvc_open(uint16_t vid, uint16_t pid, uint8_t vc_interface);
void uvc_close(uvc_dev *dev);

/// Returns bytes transferred, or -1 on failure / disallowed unit.
int uvc_get(uvc_dev *dev, uint8_t request, uint8_t unit, uint8_t selector, void *buf, uint16_t len);
int uvc_set(uvc_dev *dev, uint8_t unit, uint8_t selector, const void *buf, uint16_t len);

#endif
