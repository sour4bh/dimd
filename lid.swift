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
let faderMaxStep: Float = 0.04  // max brightness change per 50ms retarget: paces the
                                // sensor's coarse 5°+ jumps into lurch-free native ramps

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
    var commanded = brightness(of: builtin)
    var lastShown: Int = -1
    while true {
        if let angle = sensor.angle() {
            let target = faderTarget(angle: angle, top: top)
            let delta = target - commanded
            if abs(delta) > 0.005 {
                commanded += max(-faderMaxStep, min(faderMaxStep, delta))
                _ = rampBrightness(builtin, to: commanded)  // native ramp per step, like held brightness keys
            }
            if Int(angle) != lastShown {
                print("\r\(Int(angle))° → \(percent(target))   ", terminator: "")
                fflush(stdout)
                lastShown = Int(angle)
            }
        }
        usleep(50_000)  // 20Hz retargeting; the animation lives in the system
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
