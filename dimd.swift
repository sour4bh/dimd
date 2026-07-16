// dimd — idle backlight dimmer for the built-in panel.
//
// Context: `pmset -c displaysleep 0` keeps displays awake on AC power so
// long-running GUI workflows (browser automation, screen capture) never hit
// WindowServer occlusion throttling. dimd adds the missing piece: on AC with
// no external monitor, once input has been idle for --threshold seconds it
// saves the built-in panel brightness and fades the backlight to 0%; any
// input, a power-source change, or a monitor connect restores it instantly.
// On battery, or with an external monitor attached, it does nothing.

import CoreGraphics
import Foundation
import IOKit.ps

// MARK: - CLI

let usage = """
usage: dimd [--threshold <seconds>] [--status] [--selftest]
  --threshold  idle seconds before dimming (default 600)
  --status     print detected state and exit
  --selftest   exercise the brightness API (no visible change) and exit
  --demo       play the blink-blink-close → restore sequence once and exit
"""

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dimd: \(message)\n".utf8))
    exit(1)
}

enum Mode { case run, status, selftest, demo }

var threshold: TimeInterval = 600
var mode = Mode.run
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--threshold":
        guard let raw = argIterator.next(), let seconds = TimeInterval(raw), seconds > 0 else {
            die("--threshold requires a positive number of seconds")
        }
        threshold = seconds
    case "--status": mode = .status
    case "--selftest": mode = .selftest
    case "--demo": mode = .demo
    case "--help", "-h": print(usage); exit(0)
    default: die("unknown argument '\(arg)'\n\(usage)")
    }
}

// MARK: - Brightness (DisplayServices)

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

func blink(_ display: CGDirectDisplayID, at level: Float) {
    fade(display, from: level, to: 0, over: 0.12)
    fade(display, from: 0, to: level, over: 0.12)
    usleep(120_000)  // eyes open between blinks
}

// MARK: - Sensors

struct Displays {
    let builtin: CGDirectDisplayID?
    let hasExternal: Bool
}

func onlineDisplays() -> Displays {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    _ = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
    let online = ids.prefix(Int(count))
    return Displays(
        builtin: online.first { CGDisplayIsBuiltin($0) != 0 },
        hasExternal: online.contains { CGDisplayIsBuiltin($0) == 0 }
    )
}

func onACPower() -> Bool {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard let type = IOPSGetProvidingPowerSourceType(snapshot) else { return false }
    return (type.takeUnretainedValue() as String) == kIOPSACPowerValue
}

let inputEvents: [CGEventType] = [
    .mouseMoved, .keyDown, .flagsChanged, .scrollWheel,
    .leftMouseDown, .rightMouseDown, .otherMouseDown,
]

func idleSeconds() -> TimeInterval {
    inputEvents
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? .infinity
}

// MARK: - Logging

let logTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func log(_ message: String) {
    print("\(logTimestamp.string(from: Date())) \(message)")
}

// MARK: - State machine

final class Daemon {
    static let shared = Daemon()

    private let stateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/dimd/brightness")
    private var savedBrightness: Float?  // non-nil while we hold the backlight at 0
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    init() {
        // Adopt a dim held by a previous instance (daemon restarted while dimmed).
        if let text = try? String(contentsOf: stateFile, encoding: .utf8),
           let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            savedBrightness = value
        }
    }

    func run() {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer the launchd log file

        let powerSource = IOPSNotificationCreateRunLoopSource({ _ in Daemon.shared.evaluate() }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode)
        _ = CGDisplayRegisterReconfigurationCallback({ _, _, _ in Daemon.shared.evaluate() }, nil)

        // Restore the backlight before exiting on launchctl stop / Ctrl-C.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { Daemon.shared.shutdown() }
            source.resume()
            signalSources.append(source)
        }

        log("started: threshold \(Int(threshold))s\(savedBrightness != nil ? ", adopting dimmed state" : "")")
        evaluate()
        RunLoop.main.run()
    }

    func evaluate() {
        let displays = onlineDisplays()
        let shouldDim = onACPower() && !displays.hasExternal && idleSeconds() >= threshold
        if let saved = savedBrightness {
            if !shouldDim { restore(to: saved, displays: displays) }
        } else if shouldDim, let builtin = displays.builtin {
            dim(builtin)
        }
        reschedule()
    }

    private func dim(_ builtin: CGDirectDisplayID) {
        let current = brightness(of: builtin)
        let saved = current < 0.05 ? 0.5 : current  // never memorize near-black; restoring it would look broken
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(saved)".write(to: stateFile, atomically: true, encoding: .utf8)
        savedBrightness = saved

        // goodnight: blink twice, then close the eye
        blink(builtin, at: current)
        blink(builtin, at: current)
        fade(builtin, from: current, to: 0, over: 0.8)
        log("blinked goodnight, backlight 0% (was \(percent(current)), idle >= \(Int(threshold))s)")
    }

    private func restore(to saved: Float, displays: Displays) {
        guard let builtin = displays.builtin else { return }  // lid closed: retry once the panel is back online
        guard displayServices.set(builtin, saved) == 0 else {
            log("restore failed, will retry")
            return
        }
        savedBrightness = nil
        try? FileManager.default.removeItem(at: stateFile)
        log("restored backlight to \(percent(saved))")
    }

    private func reschedule() {
        // Fast tick only while dimmed so any input restores near-instantly;
        // power/display transitions arrive via callbacks, not the tick.
        let interval: TimeInterval = savedBrightness != nil ? 0.25 : 5
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let next = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in Daemon.shared.evaluate() }
        next.tolerance = interval / 10
        timer = next
    }

    func shutdown() {
        if let saved = savedBrightness { restore(to: saved, displays: onlineDisplays()) }
        log("stopped")
        exit(0)
    }
}

// MARK: - Entry

switch mode {
case .status:
    let displays = onlineDisplays()
    print("power:     \(onACPower() ? "AC" : "battery")")
    print("builtin:   \(displays.builtin.map { "id \($0), brightness \(percent(brightness(of: $0)))" } ?? "offline")")
    print("external:  \(displays.hasExternal ? "connected" : "none")")
    print("idle:      \(Int(idleSeconds()))s (threshold \(Int(threshold))s)")
case .selftest:
    guard let builtin = onlineDisplays().builtin else { die("selftest: built-in display offline") }
    let current = brightness(of: builtin)
    guard displayServices.set(builtin, current) == 0 else { die("selftest: DisplayServicesSetBrightness failed") }
    print("selftest ok: get/set on display \(builtin) at \(percent(current))")
case .demo:
    guard let builtin = onlineDisplays().builtin else { die("demo: built-in display offline") }
    let level = max(brightness(of: builtin), 0.3)  // stay visible even if the panel is currently dark
    blink(builtin, at: level)
    blink(builtin, at: level)
    fade(builtin, from: level, to: 0, over: 0.8)
    usleep(1_000_000)
    fade(builtin, from: 0, to: level, over: 0.25)
    print("demo done (restored to \(percent(level)))")
case .run:
    Daemon.shared.run()
}
