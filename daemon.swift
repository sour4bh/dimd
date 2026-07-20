import CoreGraphics
import Foundation
import IOKit.ps

let logTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func log(_ message: String) {
    print("\(logTimestamp.string(from: Date())) \(message)")
}

final class Daemon {
    static let shared = Daemon()

    private let config = Config.load()
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    // lid fader (active when config.lidfader): runs on its own tight thread —
    // main-runloop timers coalesce and share the thread, which reads as stutter.
    // The hot loop touches only these cached flags, refreshed by evaluate().
    private var sensor: LidSensor?
    private var dimActive = false
    private var builtinID: CGDirectDisplayID?

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

        if config.lidfader {
            sensor = LidSensor()
            if sensor == nil { log("lidfader: sensor unavailable, disabled") }
        }

        log("started: threshold \(Int(config.threshold))s, \(config.blinks) blinks, lidfader \(sensor != nil ? "on" : "off")\(DimState.read() != nil ? ", adopting dimmed state" : "")")
        evaluate()

        if sensor != nil {
            let thread = Thread { self.faderLoop() }
            thread.qualityOfService = .userInteractive  // steady 120Hz cadence, no coalescing
            thread.start()
        }
        RunLoop.main.run()
    }

    func evaluate() {
        let displays = onlineDisplays()
        let idle = idleSeconds()
        let hold = onACPower() && !displays.hasExternal
        if let state = DimState.read() {
            // Wake on input newer than the dim itself, or when conditions lapse.
            if !hold || idle < state.age { restore(to: state.saved, displays: displays) }
        } else if hold, idle >= config.threshold, let builtin = displays.builtin {
            dim(builtin)
        }
        dimActive = DimState.read() != nil
        builtinID = displays.builtin
        reschedule()
    }

    private func dim(_ builtin: CGDirectDisplayID) {
        let current = brightness(of: builtin)
        DimState.write(current < 0.05 ? 0.5 : current)  // never memorize near-black; restoring it would look broken
        goodnight(builtin, from: current, config: config)
        log("blinked goodnight, backlight 0% (was \(percent(current)), idle >= \(Int(config.threshold))s)")
    }

    private func restore(to saved: Float, displays: Displays, smooth: Bool = true) {
        guard let builtin = displays.builtin else { return }  // lid closed: retry once the panel is back online
        guard smooth ? rampBrightness(builtin, to: saved) : setBrightness(builtin, saved) else {
            log("restore failed, will retry")
            return
        }
        DimState.clear()
        log("restored backlight to \(percent(saved))")
    }

    private func reschedule() {
        // Fast tick only while dimmed so any input restores near-instantly;
        // power/display transitions arrive via callbacks, not the tick.
        let interval: TimeInterval = DimState.read() != nil ? 0.25 : 5
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let next = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in Daemon.shared.evaluate() }
        next.tolerance = interval / 10
        timer = next
    }

    private func faderLoop() {
        guard let sensor else { return }
        var top: Float = builtinID.map(brightness(of:)) ?? 1
        var commanded: Float = -1  // last ramp target; -1 = lid open, not controlling
        while true {
            guard let angle = sensor.angle() else { usleep(250_000); continue }

            guard !dimActive, let builtin = builtinID else {
                commanded = -1  // goodnight dim owns the panel; re-acquire after restore
                usleep(250_000)
                continue
            }

            // lid open, not controlling: just follow brightness-key adjustments
            if commanded < 0, angle >= faderCeiling {
                top = brightness(of: builtin)
                usleep(100_000)
                continue
            }

            // controlling and back above the ceiling (+2° hysteresis so hovering
            // at the boundary can't flap): hand the panel back
            if commanded >= 0, angle >= faderCeiling + 2 {
                _ = rampBrightness(builtin, to: top)
                commanded = -1
                log("lid fader released at \(Int(angle))°, restored \(percent(top))")
                usleep(100_000)
                continue
            }

            // the lid owns the backlight: hand each new target to the native
            // ramp and let the system interpolate — the brightness-key glide
            if commanded < 0 {
                commanded = brightness(of: builtin)
                log("lid fader engaged at \(Int(angle))° (top \(percent(top)))")
            }
            let target = faderTarget(angle: angle, top: top)  // clamps to top at >= ceiling
            let delta = target - commanded
            if abs(delta) > 0.005 {
                // slew-limit: pace coarse sensor jumps into small native ramps
                commanded += max(-faderMaxStep, min(faderMaxStep, delta))
                _ = rampBrightness(builtin, to: commanded)
            }
            usleep(50_000)  // 20Hz retargeting; the animation lives in the system
        }
    }

    func shutdown() {
        if let state = DimState.read() { restore(to: state.saved, displays: onlineDisplays(), smooth: false) }  // exiting: instant only
        log("stopped")
        exit(0)
    }
}
