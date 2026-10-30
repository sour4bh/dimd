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

// Brightness (and other media) keys arrive as NX_SYSDEFINED events (CGEventType 14).
// Depending on the keyboard they may not also register as keyDown, so idleSeconds()
// can miss them. The type also fires for non-key reasons, so only use it together
// with an observed brightness change.
private let systemDefinedEvent = CGEventType(rawValue: 14)!

func secondsSinceSystemDefinedEvent() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: systemDefinedEvent)
}
