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

    // lid fader state (active when config.lidfader)
    private var sensor: LidSensor?
    private var faderTimer: Timer?
    private var faderTop: Float = 1     // the user's setpoint; tracked while the lid is open
    private var faderLevel: Float = -1  // last level we set; -1 = lid open, not controlling
    private var lastAngle: Float = -1
    private var lastMovement = Date.distantPast

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
            if sensor == nil {
                log("lidfader: sensor unavailable, disabled")
            } else {
                if let builtin = onlineDisplays().builtin { faderTop = brightness(of: builtin) }
                scheduleFader(fast: false)
            }
        }

        log("started: threshold \(Int(config.threshold))s, \(config.blinks) blinks, lidfader \(sensor != nil ? "on" : "off")\(DimState.read() != nil ? ", adopting dimmed state" : "")")
        evaluate()
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
        if smooth { fade(builtin, from: brightness(of: builtin), to: saved, over: 0.3) }
        guard setBrightness(builtin, saved) else {
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

    func faderTick() {
        guard let sensor, let angle = sensor.angle() else { return }
        let moving = lastAngle >= 0 && abs(angle - lastAngle) >= 1
        lastAngle = angle
        if moving { lastMovement = Date() }
        let movedRecently = Date().timeIntervalSince(lastMovement) < 2

        guard DimState.read() == nil, let builtin = onlineDisplays().builtin else {
            faderLevel = -1  // goodnight dim owns the panel; re-acquire after restore
            scheduleFader(fast: false)
            return
        }

        if angle >= faderCeiling {
            if faderLevel >= 0 {
                // lid back up: glide to the setpoint and hand the panel back
                fade(builtin, from: faderLevel, to: faderTop, over: 0.25)
                _ = setBrightness(builtin, faderTop)
                faderLevel = -1
                log("lid fader released at \(Int(angle))°, restored \(percent(faderTop))")
            } else {
                faderTop = brightness(of: builtin)  // follow brightness-key adjustments
            }
            scheduleFader(fast: movedRecently)
            return
        }

        // below the ceiling: the lid owns the backlight
        if faderLevel < 0 {
            faderLevel = brightness(of: builtin)
            log("lid fader engaged at \(Int(angle))° (top \(percent(faderTop)))")
        }
        let target = faderTarget(angle: angle, top: faderTop)
        let converged = abs(faderLevel - target) <= 0.002
        if !converged {
            faderLevel += (target - faderLevel) * 0.12  // low-pass glide
            _ = setBrightness(builtin, faderLevel)
        }
        scheduleFader(fast: movedRecently || !converged)
    }

    private func scheduleFader(fast: Bool) {
        // 60 Hz only while the lid is moving or the glide is converging;
        // 4 Hz to notice the next movement.
        let interval: TimeInterval = fast ? 0.016 : 0.25
        guard faderTimer?.timeInterval != interval else { return }
        faderTimer?.invalidate()
        let next = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in Daemon.shared.faderTick() }
        next.tolerance = fast ? 0 : 0.05
        faderTimer = next
    }

    func shutdown() {
        if let state = DimState.read() { restore(to: state.saved, displays: onlineDisplays(), smooth: false) }  // exiting: instant only
        log("stopped")
        exit(0)
    }
}
