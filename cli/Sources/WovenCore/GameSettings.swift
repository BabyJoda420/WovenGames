// Per-game settings: ~/Library/Application Support/WovenGames/games/<appid>.env
//
// KEY=VALUE lines the compat tool's run script exports before starting the game. They override
// global.env; launch options set in Steam still win. Lines this type does not know are kept.

import Foundation

public struct GameSettings: Equatable, Sendable {
    public enum BackendChoice: String, CaseIterable, Identifiable, Sendable {
        case auto, d3dmetal, dxmt, wined3d
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .auto: "Automatic"
            case .d3dmetal: "D3DMetal (DirectX 11/12)"
            case .dxmt: "DXMT (DirectX 10/11)"
            case .wined3d: "WineD3D (OpenGL, older games)"
            }
        }
    }

    public var backend: BackendChoice = .auto
    public var metalHUD = false
    public var msync = true
    public var retina = false
    /// extra arguments for the game itself, e.g. "-dx11"
    public var gameArgs = ""
    /// an installed runner's id to use instead of the current one; empty means the current
    public var runner = ""
    /// lines for keys this type does not manage, kept verbatim
    public var otherLines: [String] = []

    static let backendKey = "CX_GRAPHICS_BACKEND"
    static let hudKey = "MTL_HUD_ENABLED"
    static let msyncKey = "WINEMSYNC"
    static let retinaKey = "WOVEN_RETINA"
    static let argsKey = "WOVEN_GAME_ARGS"
    static let runnerKey = "WOVEN_RUNNER"

    public init() {}

    public static func file(appID: String, paths: Paths = Paths()) -> URL {
        paths.support.appending(path: "games/\(appID).env")
    }

    public static func load(appID: String, paths: Paths = Paths()) -> GameSettings {
        guard let text = try? String(contentsOf: file(appID: appID, paths: paths), encoding: .utf8) else { return GameSettings() }
        return GameSettings(parsing: text)
    }

    public init(parsing text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // comments and anything without a KEY= are kept as they are
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard !line.hasPrefix("#"), parts.count == 2, let key = parts.first, !key.isEmpty else {
                otherLines.append(line)
                continue
            }
            if !assign(key, parts[1]) { otherLines.append(line) }
        }
    }

    /// Sets a setting this type manages; false for any other key.
    mutating func assign(_ key: String, _ value: String) -> Bool {
        switch key {
        case Self.backendKey: backend = BackendChoice(rawValue: value) ?? .auto
        case Self.hudKey: metalHUD = value == "1"
        case Self.msyncKey: msync = value != "0"
        case Self.retinaKey, "NOTPROTON_RETINA": retina = value == "1"  // older name still read
        case Self.argsKey: gameArgs = value
        case Self.runnerKey: runner = value
        default: return false
        }
        return true
    }

    /// Only what differs from the defaults is written, so the run script's defaults still apply.
    public var text: String {
        var lines: [String] = []
        if backend != .auto { lines.append("\(Self.backendKey)=\(backend.rawValue)") }
        if metalHUD { lines.append("\(Self.hudKey)=1") }
        if !msync { lines.append("\(Self.msyncKey)=0") }
        if retina { lines.append("\(Self.retinaKey)=1") }
        let args = gameArgs.trimmingCharacters(in: .whitespaces)
        if !args.isEmpty { lines.append("\(Self.argsKey)=\(args)") }
        if !runner.isEmpty { lines.append("\(Self.runnerKey)=\(runner)") }
        lines += otherLines
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Known-good defaults shipped with WovenGames (compat/<appid>.env), if any.
    public static func recommended(appID: String, paths: Paths = Paths()) -> GameSettings? {
        let url = paths.support.appending(path: "compat/\(appID).env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return GameSettings(parsing: text)
    }

    /// One line for the UI, e.g. "DXMT · -dx11".
    public var summary: String {
        var parts: [String] = []
        if backend != .auto { parts.append(backend.label.components(separatedBy: " (").first ?? backend.rawValue) }
        if !gameArgs.isEmpty { parts.append(gameArgs) }
        if !runner.isEmpty { parts.append(runner) }
        if metalHUD { parts.append("HUD") }
        if retina { parts.append("Retina") }
        if !msync { parts.append("msync off") }
        return parts.isEmpty ? "defaults" : parts.joined(separator: " · ")
    }

    public func save(appID: String, paths: Paths = Paths()) throws {
        let url = Self.file(appID: appID, paths: paths)
        if text.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
