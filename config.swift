import Foundation

struct Config {
    var threshold: TimeInterval = 600  // idle seconds before dimming
    var blinks: Int = 2                // goodnight blinks before the fade
    var dip: Float = 0.35              // blink dip depth, fraction of current brightness
    var fade: TimeInterval = 0.9       // final fade-to-black duration, seconds

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/dimd/config")

    static func load() -> Config {
        var config = Config()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return config }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count != 2 || !config.set(key: parts[0], value: parts[1]) {
                FileHandle.standardError.write(Data("dimd: ignoring bad config line '\(trimmed)'\n".utf8))
            }
        }
        return config
    }

    mutating func set(key: String, value: String) -> Bool {
        switch key {
        case "threshold":
            guard let parsed = TimeInterval(value), parsed > 0 else { return false }
            threshold = parsed
        case "blinks":
            guard let parsed = Int(value), (0...10).contains(parsed) else { return false }
            blinks = parsed
        case "dip":
            guard let parsed = Float(value), (0...1).contains(parsed) else { return false }
            dip = parsed
        case "fade":
            guard let parsed = TimeInterval(value), parsed > 0 else { return false }
            fade = parsed
        default:
            return false
        }
        return true
    }

    func save() {
        let text = """
        threshold=\(Int(threshold))
        blinks=\(blinks)
        dip=\(dip)
        fade=\(fade)

        """
        do {
            try FileManager.default.createDirectory(at: Config.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: Config.file, atomically: true, encoding: .utf8)
        } catch {
            die("cannot write \(Config.file.path): \(error.localizedDescription)")
        }
    }
}
