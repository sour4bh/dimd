import CoreGraphics
import Foundation
import IOKit.ps

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
