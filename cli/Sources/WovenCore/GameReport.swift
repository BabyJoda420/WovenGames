// Game compatibility reports and player notes in compat/<appid>.env

import Darwin
import Foundation

/// Player-facing game compatibility report and notes shipped in `compat/<appid>.env`.
///
/// Lines starting with `#! ` are parsed as report metadata:
/// ```
/// #! rating=playable
/// #! tested=MacBook Air (M4, 16 GB)
/// #! note=About 35 fps at 1280x832 on the lowest preset. Looks rough, but plays.
/// #! note=Don't use DXMT: it draws the shadows as a checkerboard.
/// ```
public struct GameReport: Equatable, Sendable {
    public enum Rating: String, CaseIterable, Sendable {
        case great
        case playable
        case poor
        case broken

        /// Plain English label for players.
        public var label: String {
            switch self {
            case .great: "Runs well"
            case .playable: "Playable with compromises"
            case .poor: "Runs poorly"
            case .broken: "Doesn't work"
            }
        }
    }

    public var rating: Rating?
    public var tested: String
    public var notes: [String]

    public init(rating: Rating? = nil, tested: String = "", notes: [String] = []) {
        self.rating = rating
        self.tested = tested
        self.notes = notes
    }

    /// Parses `#! ` metadata lines from an env file.
    /// Returns `nil` when there is no rating and no note.
    public init?(parsing text: String) {
        var parsedRating: Rating?
        var parsedTested = ""
        var parsedNotes: [String] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#!") else { continue }
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(parts[1].trimmingCharacters(in: .whitespaces).prefix(300))

            switch key {
            case "rating":
                if let r = Rating(rawValue: val.lowercased()) {
                    parsedRating = r
                }
            case "tested":
                parsedTested = val
            case "note":
                if parsedNotes.count < 6 && !val.isEmpty {
                    parsedNotes.append(val)
                }
            default:
                break
            }
        }

        guard parsedRating != nil || !parsedNotes.isEmpty else { return nil }
        self.rating = parsedRating
        self.tested = parsedTested
        self.notes = parsedNotes
    }

    /// Reads `paths.support/compat/<appid>.env`.
    public static func load(appID: String, paths: Paths = Paths()) -> GameReport? {
        let url = paths.support.appending(path: "compat/\(appID).env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return GameReport(parsing: text)
    }
}

/// Hardware identity of a Mac (Apple Silicon chip and memory), for comparing against tested configurations.
public struct MacInfo: Equatable, Sendable, CustomStringConvertible {
    public var chip: String
    public var memoryGB: Int

    public init(chip: String, memoryGB: Int) {
        self.chip = chip
        self.memoryGB = memoryGB
    }

    /// The active Mac's chip and memory.
    public static var current: MacInfo {
        let chip = brandString()
        let mem = Int(round(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0))
        return MacInfo(chip: chip, memoryGB: max(1, mem))
    }

    public var description: String {
        if chip.isEmpty {
            return "\(memoryGB) GB"
        }
        return "\(chip), \(memoryGB) GB"
    }

    private static func brandString() -> String {
        var size = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                let str = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !str.isEmpty { return str }
            }
        }
        let fallback = Shell.capture("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Apple Silicon" : fallback
    }
}
