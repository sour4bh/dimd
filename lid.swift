import CoreGraphics
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

// The fader: lid angle drives the backlight directly. Proof-of-concept for
// lid-angle automations.
private var faderDisplay: CGDirectDisplayID?
private var faderOriginal: Float?

func runFader() {
    guard let builtin = onlineDisplays().builtin else { die("built-in display offline") }
    guard lidAngle() != nil else { die("lid angle sensor not found") }
    faderDisplay = builtin
    faderOriginal = brightness(of: builtin)
    signal(SIGINT) { _ in
        if let display = faderDisplay, let original = faderOriginal {
            _ = displayServices.set(display, original)
        }
        print("\ndone")
        exit(0)
    }
    print("lid = brightness fader (15°–105°) — Ctrl-C to stop")
    var last: Float = -1
    while true {
        if let angle = lidAngle() {
            let level = min(max((angle - 15) / 90, 0), 1)
            if abs(level - last) > 0.005 {  // only touch the panel when the lid actually moved
                _ = displayServices.set(builtin, level)
                last = level
            }
            print("\r\(Int(angle))° → \(percent(level))   ", terminator: "")
            fflush(stdout)
        }
        usleep(50_000)
    }
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
