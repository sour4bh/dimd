import Foundation
import IOKit.hid

// Apple Silicon MacBooks expose the lid angle as a HID sensor (usage page
// 0x20 Sensor, usage 0x8A); feature report 1 carries the angle in degrees.
// Groundwork for lid-angle automations.
func lidAngle() -> Float? {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [kIOHIDDeviceUsagePageKey: 0x20, kIOHIDDeviceUsageKey: 0x8A]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
    for device in devices {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
        defer { _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        var report = [UInt8](repeating: 0, count: 8)
        var length: CFIndex = report.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              length >= 3 else { continue }
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        return raw > 360 ? Float(raw) / 100 : Float(raw)  // some firmware reports hundredths of a degree
    }
    return nil
}

func runLid(watch: Bool) {
    guard let first = lidAngle() else { die("lid angle sensor not found") }
    if !watch {
        print("lid angle: \(Int(first))°")
        return
    }
    var angle = first
    while true {
        print("\rlid angle: \(Int(angle))°   ", terminator: "")
        fflush(stdout)
        usleep(100_000)
        angle = lidAngle() ?? angle
    }
}
