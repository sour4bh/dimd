import CoreGraphics
import Foundation

func runStatus() {
    let config = Config.load()
    let displays = onlineDisplays()
    print("power:     \(onACPower() ? "AC" : "battery")")
    print("builtin:   \(displays.builtin.map { "id \($0), brightness \(percent(brightness(of: $0)))" } ?? "offline")")
    print("external:  \(displays.hasExternal ? "connected" : "none")")
    print("idle:      \(Int(idleSeconds()))s (threshold \(Int(config.threshold))s)")
    print("state:     \(DimState.read() != nil ? "dimmed" : "normal")")
    print("lidfader:  \(config.lidfader ? "on" : "off")")
    if let angle = lidAngle() { print("lid:       \(Int(angle))°") }
}

func runBlink() {
    let config = Config.load()
    guard let builtin = onlineDisplays().builtin else { die("built-in display offline") }
    let original = brightness(of: builtin)
    let level = max(original, 0.3)  // stay visible even if the panel is currently dark
    for _ in 0..<max(config.blinks, 1) { blink(builtin, at: level, dip: config.dip) }
    if level != original { _ = displayServices.set(builtin, original) }
}

func runDemo() {
    let config = Config.load()
    guard let builtin = onlineDisplays().builtin else { die("built-in display offline") }
    let original = brightness(of: builtin)
    let level = max(original, 0.3)
    goodnight(builtin, from: level, config: config)
    usleep(1_000_000)
    fade(builtin, from: 0, to: original, over: 0.25)
    print("demo done (restored to \(percent(original)))")
}

func runDim() {
    let config = Config.load()
    guard DimState.read() == nil else { die("already dimmed") }
    let displays = onlineDisplays()
    guard let builtin = displays.builtin else { die("built-in display offline") }
    let current = brightness(of: builtin)
    DimState.write(current < 0.05 ? 0.5 : current)
    goodnight(builtin, from: current, config: config)
    if !(onACPower() && !displays.hasExternal) {
        print("note: the daemon holds a dim only on AC with no external monitor — this will restore within ~5s")
    }
}

func runWake() {
    guard let state = DimState.read() else { die("not dimmed") }
    guard let builtin = onlineDisplays().builtin else { die("built-in display offline") }
    guard setBrightness(builtin, state.saved) else { die("brightness restore failed") }
    DimState.clear()
    print("restored backlight to \(percent(state.saved))")
}

func runSet(_ args: [String]) {
    guard args.count == 1, let target = Int(args[0]), (0...100).contains(target) else {
        die("usage: dimd set <0-100>")
    }
    guard let builtin = onlineDisplays().builtin else { die("built-in display offline") }
    let value = Float(target) / 100
    fade(builtin, from: brightness(of: builtin), to: value, over: 0.4)
    guard setBrightness(builtin, value) else { die("brightness set failed") }
    print("brightness: \(percent(brightness(of: builtin)))")
}

func runSelftest() {
    guard let builtin = onlineDisplays().builtin else { die("selftest: built-in display offline") }
    let current = brightness(of: builtin)
    guard displayServices.set(builtin, current) == 0 else { die("selftest: DisplayServicesSetBrightness failed") }
    print("selftest ok: get/set on display \(builtin) at \(percent(current))")
}

func runConfig(_ args: [String]) {
    var config = Config.load()
    if args.isEmpty {
        print("threshold=\(Int(config.threshold))  # idle seconds before dimming")
        print("blinks=\(config.blinks)       # goodnight blinks before the fade")
        print("dip=\(config.dip)      # blink dip depth (0-1, fraction of brightness)")
        print("fade=\(config.fade)      # fade-to-black seconds")
        print("lidfader=\(config.lidfader ? "on" : "off")  # lid angle drives the backlight (daemon)")
        print("file: \(Config.file.path)")
        return
    }
    guard args.count == 3, args[0] == "set" else { die("usage: dimd config set <key> <value>") }
    guard config.set(key: args[1], value: args[2]) else {
        die("invalid \(args[1])=\(args[2]) (keys: threshold, blinks, dip, fade, lidfader)")
    }
    config.save()
    print("\(args[1])=\(args[2]) saved")
    restartDaemonIfLoaded()
}

private func restartDaemonIfLoaded() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["kickstart", "-k", "gui/\(getuid())/local.dimd"]
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return }
    task.waitUntilExit()
    if task.terminationStatus == 0 { print("daemon restarted") }
}
