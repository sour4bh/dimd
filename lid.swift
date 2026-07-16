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

// The fader: lid angle drives the backlight. Below faderCeiling the lid owns
// the brightness, scaling the user's setpoint down to 0% at faderFloor;
// at/above faderCeiling the panel is untouched, so no working posture dims.
let faderFloor: Float = 15
let faderCeiling: Float = 69

func faderTarget(angle: Float, top: Float) -> Float {
    top * min(max((angle - faderFloor) / (faderCeiling - faderFloor), 0), 1)
}

private var faderDisplay: CGDirectDisplayID?
private var faderOriginal: Float?

func runFader() {
    guard !Config.load().lidfader else {
        die("lidfader is on in the daemon — it already owns the backlight (dimd config set lidfader off)")
    }
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
    let top = (faderOriginal ?? 0) < 0.05 ? 0.5 : faderOriginal!  // sane ceiling if starting near-black
    print("lid = brightness fader (\(Int(faderFloor))°–\(Int(faderCeiling))°, \(percent(top)) above) — Ctrl-C to stop")
    var level = brightness(of: builtin)
    var lastSet: Float = -1
    var lastShown: Int = -1
    while true {
        if let angle = sensor.angle() {
            let target = faderTarget(angle: angle, top: top)
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
