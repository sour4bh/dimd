import Foundation

// The statefile is the single source of truth for "dimmed": the daemon,
// `dimd dim`, and `dimd wake` all coordinate through it, so a manual dim gets
// the daemon's restore-on-input behavior for free, and a dim survives daemon
// restarts. `age` (seconds since the dim began) lets the daemon distinguish
// input that happened after the dim from the input that preceded it.
enum DimState {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/dimd/brightness")

    static func read() -> (saved: Float, age: TimeInterval)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date
        return (value, modified.map { Date().timeIntervalSince($0) } ?? 0)
    }

    static func write(_ saved: Float) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(saved)".write(to: file, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
