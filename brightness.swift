import CoreGraphics
import Foundation

// DisplayServices is a private framework, but it is the only per-display
// brightness API that reaches the built-in panel on Apple Silicon (same
// route the `brightness` CLI uses). Fail fast if it ever disappears.
typealias BrightnessGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias BrightnessSet = @convention(c) (CGDirectDisplayID, Float) -> Int32

let displayServices: (get: BrightnessGet, set: BrightnessSet) = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
          let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
        die("DisplayServices framework unavailable — cannot control built-in brightness")
    }
    return (
        unsafeBitCast(getSymbol, to: BrightnessGet.self),
        unsafeBitCast(setSymbol, to: BrightnessSet.self)
    )
}()

func brightness(of display: CGDirectDisplayID) -> Float {
    var value: Float = 0
    _ = displayServices.get(display, &value)
    return value
}

func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }

func fade(_ display: CGDirectDisplayID, from start: Float, to end: Float, over duration: TimeInterval) {
    let steps = max(Int(duration / 0.02), 1)
    for step in 1...steps {
        _ = displayServices.set(display, start + (end - start) * Float(step) / Float(steps))
        usleep(20_000)
    }
}

func blink(_ display: CGDirectDisplayID, at level: Float, dip dipFraction: Float) {
    let dip = level * dipFraction  // sleepy half-blink, not a strobe to black
    fade(display, from: level, to: dip, over: 0.12)
    fade(display, from: dip, to: level, over: 0.12)
    usleep(100_000)  // eyes open between blinks
}

// goodnight: blink, then close the eye
func goodnight(_ display: CGDirectDisplayID, from level: Float, config: Config) {
    for _ in 0..<config.blinks { blink(display, at: level, dip: config.dip) }
    fade(display, from: level, to: 0, over: config.fade)
}
