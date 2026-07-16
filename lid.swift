import CoreGraphics
import Foundation
import IOKit.hid

// Apple Silicon MacBooks expose the lid angle as a HID sensor (usage page
// 0x20 Sensor, usage 0x8A); feature report 1 carries the angle in degrees.
// Groundwork for lid-angle automations.
final class LidSensor {
    private let manager: IOHIDManager  // keeps the device connection alive
    private let device: IOHIDDevice

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [kIOHIDDeviceUsagePageKey: 0x20, kIOHIDDeviceUsageKey: 0x8A]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        for candidate in devices where IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            if Self.read(candidate) != nil {
                device = candidate
                return
            }
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return nil
    }

    func angle() -> Float? { Self.read(device) }

    private static func read(_ device: IOHIDDevice) -> Float? {
        var report = [UInt8](repeating: 0, count: 8)
        var length: CFIndex = report.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              length >= 3 else { return nil }
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        return raw > 360 ? Float(raw) / 100 : Float(raw)  // some firmware reports hundredths of a degree
    }
}

func lidAngle() -> Float? { LidSensor()?.angle() }

// The fader: lid angle drives the backlight directly. Proof-of-concept for
// lid-angle automations.
private var faderDisplay: CGDirectDisplayID?
private var faderOriginal: Float?

func runFader() {
    guard let builtin = onlineDisplays().builtin else { die("built-in display offline") }
    guard let sensor = LidSensor() else { die("lid angle sensor not found") }
    faderDisplay = builtin
    faderOriginal = brightness(of: builtin)
    signal(SIGINT) { _ in
        if let display = faderDisplay, let original = faderOriginal {
            _ = setBrightness(display, original)
        }
        print("\ndone")
        exit(0)
    }
    // The fader tops out at *your* brightness, not 100%: from 69° up the
    // panel stays where you had it — normal working postures never dim —
    // and dimming only starts once the lid tilts toward you.
    let floor: Float = 15, ceiling: Float = 69
    let top = (faderOriginal ?? 0) < 0.05 ? 0.5 : faderOriginal!  // sane ceiling if starting near-black
    print("lid = brightness fader (\(Int(floor))°–\(Int(ceiling))°, \(percent(top)) above) — Ctrl-C to stop")
    var level = brightness(of: builtin)
    var lastSet: Float = -1
    var lastShown: Int = -1
    while true {
        if let angle = sensor.angle() {
            let target = top * min(max((angle - floor) / (ceiling - floor), 0), 1)
            level += (target - level) * 0.06  // low-pass: ~140ms glide
            if abs(level - lastSet) > 0.0005 {
                _ = displayServices.set(builtin, level)
                lastSet = level
            }
            if Int(angle) != lastShown {
                print("\r\(Int(angle))° → \(percent(target))   ", terminator: "")
                fflush(stdout)
                lastShown = Int(angle)
            }
        }
        usleep(8_000)  // ~120 Hz: per-frame steps far below what the eye can catch
    }
}

func runLid(watch: Bool) {
    guard let sensor = LidSensor(), let first = sensor.angle() else { die("lid angle sensor not found") }
    if !watch {
        print("lid angle: \(Int(first))°")
        return
    }
    var angle = first
    while true {
        print("\rlid angle: \(Int(angle))°   ", terminator: "")
        fflush(stdout)
        usleep(100_000)
        angle = sensor.angle() ?? angle
    }
}
