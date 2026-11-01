import Foundation
import IOKit

/// How the camera is attached: negotiated USB link speed, and whether its USB
/// controller is in a Thunderbolt dock rather than the Mac. (Hubs say little:
/// the WB7022 has a Realtek USB 3 hub built in, so one is always there.)
struct USBLink: Equatable {
    let bitsPerSecond: Int
    let throughDock: Bool

    /// The camera only sends uncompressed video, so 4K needs a USB 3 link.
    var isUSB3: Bool { bitsPerSecond >= 5_000_000_000 }

    var label: String {
        switch bitsPerSecond {
        case 5_000_000_000...:
            return "USB 3 · \(bitsPerSecond / 1_000_000_000) Gbps"
        case 480_000_000...:
            return "USB 2 · 480 Mbps"
        default:
            return "USB 1 · \(bitsPerSecond / 1_000_000) Mbps"
        }
    }

    static func current() -> USBLink? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        matching["idVendor"] = NSNumber(value: UVCDevice.vendorID)
        matching["idProduct"] = NSNumber(value: UVCDevice.productID)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let speed = IORegistryEntryCreateCFProperty(service, "UsbLinkSpeed" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }

        return USBLink(bitsPerSecond: speed.intValue, throughDock: controllerIsTunnelled(above: service))
    }

    /// Walks up past any hubs to the USB controller. A dock's controller sits on
    /// PCIe tunnelled over Thunderbolt, which macOS flags as IOPCITunnelled.
    private static func controllerIsTunnelled(above device: io_service_t) -> Bool {
        var entry = device
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        while IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOUSBPlane, &parent) == KERN_SUCCESS else { return false }
            IOObjectRelease(entry)
            entry = parent
        }
        let flag = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "IOPCITunnelled" as CFString, kCFAllocatorDefault,
                                                   IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return (flag as? Bool) == true
    }
}
