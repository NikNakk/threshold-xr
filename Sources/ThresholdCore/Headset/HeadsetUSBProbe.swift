import Foundation
import IOKit
import IOKit.usb

/// A USB device seen in the IOKit registry.
public struct USBDeviceInfo: Sendable, Hashable {
    public var vendorID: Int
    public var productID: Int
    public var productName: String?
    public var locationID: Int?

    public init(vendorID: Int, productID: Int, productName: String? = nil, locationID: Int? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.locationID = locationID
    }
}

/// What USB tells us about the PS VR2 headset, without opening any device.
public struct HeadsetUSBState: Sendable, Equatable {
    /// PS VR2 headset (Sony 0x054C, product 0x0CDE, from Monado's psvr2 driver).
    public var headset: USBDeviceInfo?
    /// Other Sony devices (adapter hubs, controllers) that may help diagnose
    /// a headset that is plugged in but not powered.
    public var otherSonyDevices: [USBDeviceInfo]

    public var headsetPresent: Bool { headset != nil }
}

public protocol USBDeviceEnumerating: Sendable {
    func devices(vendorID: Int) -> [USBDeviceInfo]
}

public enum PSVR2USB {
    public static let vendorID = 0x054C
    public static let headsetProductID = 0x0CDE

    public static func state(from devices: [USBDeviceInfo]) -> HeadsetUSBState {
        let sony = devices.filter { $0.vendorID == vendorID }
        return HeadsetUSBState(
            headset: sony.first { $0.productID == headsetProductID },
            otherSonyDevices: sony.filter { $0.productID != headsetProductID }
        )
    }
}

/// Reads the IOKit USB registry. Passive: it does not open or claim devices,
/// so it is safe while Monado owns the headset.
public struct IOKitUSBEnumerator: USBDeviceEnumerating {
    public init() {}

    public func devices(vendorID: Int) -> [USBDeviceInfo] {
        // Match every USB device and filter here: adding idVendor to the
        // matching dictionary silently matched nothing on macOS 27.
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [USBDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let vendor = (property(kUSBVendorID) as? NSNumber)?.intValue, vendor == vendorID else { continue }
            let product = (property(kUSBProductID) as? NSNumber)?.intValue ?? 0
            var name = property(kUSBProductString) as? String ?? property("USB Product Name") as? String
            if name?.isEmpty == true { name = nil }
            let location = (property(kUSBDevicePropertyLocationID) as? NSNumber)?.intValue
            result.append(USBDeviceInfo(vendorID: vendor, productID: product, productName: name, locationID: location))
        }
        return result
    }
}
