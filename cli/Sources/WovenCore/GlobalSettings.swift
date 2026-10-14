// Settings for every game: ~/Library/Application Support/WovenGames/global.env
//
// KEY=VALUE lines the run script exports before each game; a game's own settings and its
// launch options in Steam win over them. The app manages only the Metal FPS overlay here.
// Everything else in the file is someone's hand edit, so it stays exactly as written.

import Foundation

public struct GlobalSettings: Sendable {
    public var paths: Paths

    public init(paths: Paths = Paths()) { self.paths = paths }

    public var file: URL { paths.support.appending(path: "global.env") }

    static let hudKey = "MTL_HUD_ENABLED"

    /// Metal's performance HUD (FPS) in every game.
    public var fpsOverlay: Bool {
        lines().contains { Self.hudValue(of: $0) == "1" }
    }

    /// Writes or removes MTL_HUD_ENABLED=1; deletes the file when nothing else is left in it.
    public func setFPSOverlay(_ on: Bool) throws {
        // every HUD line goes, so an earlier MTL_HUD_ENABLED=0 cannot win over the new one
        // (the run script keeps the first value it reads)
        var kept = lines().filter { Self.hudValue(of: $0) == nil }
        if on { kept.append("\(Self.hudKey)=1") }
        let fm = FileManager.default
        if kept.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            if fm.fileExists(atPath: file.path(percentEncoded: false)) { try fm.removeItem(at: file) }
            return
        }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (kept.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The file's lines without the final newline; empty when there is no file.
    func lines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The value when `line` sets the HUD key, else nil.
    static func hudValue(of line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == hudKey else { return nil }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
