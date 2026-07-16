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

        log("started: threshold \(Int(config.threshold))s, \(config.blinks) blinks\(DimState.read() != nil ? ", adopting dimmed state" : "")")
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

    private func restore(to saved: Float, displays: Displays) {
        guard let builtin = displays.builtin else { return }  // lid closed: retry once the panel is back online
        guard displayServices.set(builtin, saved) == 0 else {
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

    func shutdown() {
        if let state = DimState.read() { restore(to: state.saved, displays: onlineDisplays()) }
        log("stopped")
        exit(0)
    }
}
