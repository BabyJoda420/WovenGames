// Why a game did not start, in words a player understands.
//
// Steam reports a failed launch with codes like "OS Error 260" or not at all. The launch
// script's log, the game's launch options in Steam and the installed engine usually say what
// happened; these rules turn that into a sentence and, where there is one, a fix.

import Foundation

public struct LaunchFinding: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Fix: Equatable, Sendable {
        case resetPrefix
        case installEngine
        /// corrected launch options, for the user to paste into Steam
        case launchOptions(String)
        case switchBackend(GameSettings.BackendChoice)
        case useSettings(backend: GameSettings.BackendChoice, gameArgs: String)
        case openLaunchLog
    }

    /// Where a finding comes from: the game's setup (engine, launch options), true before and
    /// after any launch, or what the run log says about the last launch.
    public enum Source: Sendable {
        case setup
        case lastRun
    }

    public var severity: Severity
    public var title: String
    public var detail: String
    public var fix: Fix?
    public var source: Source = .setup
    public var misplacedSettings: [String] = []
    public var cleanedOptions: String? = nil

    public var id: String { title }

    public init(severity: Severity, title: String, detail: String, fix: Fix? = nil, source: Source = .setup,
                misplacedSettings: [String] = [], cleanedOptions: String? = nil) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fix = fix
        self.source = source
        self.misplacedSettings = misplacedSettings
        self.cleanedOptions = cleanedOptions
    }
}

/// A game's launch options in Steam (Properties → General), from localconfig.vdf.
public struct SteamLaunchOptions: Equatable, Sendable {
    public var raw: String

    public init(_ raw: String) { self.raw = raw }

    /// Settings the launch script takes from launch options (the same names it accepts).
    static func isSetting(_ token: String) -> Bool {
        let prefixes = ["CX_GRAPHICS", "D3DM_", "DXMT_", "DXVK_", "MTL_", "NOTPROTON_", "ROSETTA_", "WINE", "WOVEN_"]
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[..<eq]
        return prefixes.contains { name.hasPrefix($0) }
    }

    var tokens: [String] { raw.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// NAME=value settings written before %command%: Steam on macOS then cannot start the game
    /// ("OS Error 260"). Without %command% Steam appends the options to the command, where the
    /// launch script reads them, so only options in front of %command% are misplaced.
    public var misplacedSettings: [String] {
        let t = tokens
        guard let end = t.firstIndex(of: "%command%") else { return [] }
        return t[..<end].filter(Self.isSetting)
    }

    public var hasCommand: Bool { tokens.contains("%command%") }

    /// Settings that do reach WovenGames, e.g. ["CX_GRAPHICS_BACKEND=dxmt"].
    public var settings: [String] {
        let t = tokens
        guard let start = t.firstIndex(of: "%command%") else { return t.filter(Self.isSetting) }
        return t[(start + 1)...].filter(Self.isSetting)
    }

    /// The same options with every setting moved after %command%.
    public var corrected: String {
        let t = tokens
        // without %command%, every option was for the game: all of it goes after %command%
        guard hasCommand else { return (["%command%"] + t).joined(separator: " ") }
        let misplaced = Set(misplacedSettings)
        let before = t.prefix(while: { $0 != "%command%" }).filter { !misplaced.contains($0) }
        let after = t.drop(while: { $0 != "%command%" }).dropFirst()
        return (before + ["%command%"] + after + misplacedSettings.filter { !after.contains($0) }).joined(separator: " ")
    }

    /// The same options with misplaced settings removed.
    public var cleaned: String {
        let t = tokens
        guard hasCommand else { return raw }
        let misplaced = Set(misplacedSettings)
        let before = t.prefix(while: { $0 != "%command%" }).filter { !misplaced.contains($0) }
        let after = t.drop(while: { $0 != "%command%" }).dropFirst()
        return (before + ["%command%"] + after).joined(separator: " ")
    }

    /// Reads the options for `appID`, from the most recently used Steam account on this Mac.
    public static func read(appID: String, paths: Paths = Paths()) -> SteamLaunchOptions? {
        let userdata = paths.steam.userData.appending(path: "userdata")
        let fm = FileManager.default
        let configs = ((try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: "config/localconfig.vdf") }
            .filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        guard let newest = configs.first, let text = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        return find(appID: appID, in: VDF.parse(text)).map(SteamLaunchOptions.init)
    }

    /// apps/<appid>/LaunchOptions, wherever "apps" sits in the tree.
    static func find(appID: String, in node: VDF) -> String? {
        for (key, value) in node.pairs {
            if key.lowercased() == "apps", let options = value[appID]?["LaunchOptions"]?.string {
                return options.isEmpty ? nil : options
            }
            if case .object = value, let found = find(appID: appID, in: value) { return found }
        }
        return nil
    }
}

public enum LaunchDiagnosis {
    /// Whether an installed game was built with Unreal Engine (depth up to 4).
    public static func isUnrealEngine(installDir: URL) -> Bool {
        let fm = FileManager.default
        let rootPath = installDir.path(percentEncoded: false)
        guard fm.fileExists(atPath: rootPath) else { return false }

        let directEngineBinaries = installDir.appending(path: "Engine/Binaries")
        if fm.fileExists(atPath: directEngineBinaries.path(percentEncoded: false)) {
            return true
        }

        guard let enumerator = fm.enumerator(at: installDir,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return false }
        while let file = enumerator.nextObject() as? URL {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = file.lastPathComponent
            if isDir {
                if name.lowercased() == "binaries" && file.deletingLastPathComponent().lastPathComponent.lowercased() == "engine" {
                    return true
                }
            } else {
                if name.hasSuffix("-Shipping.exe") || name.hasSuffix("-shipping.exe") {
                    return true
                }
            }
        }
        return false
    }

    /// Appends `arg` to `existing` arguments if `existing` does not already contain it.
    public static func addingArg(_ arg: String, to existing: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return arg }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.contains(arg) { return trimmed }
        return "\(trimmed) \(arg)"
    }

    /// Everything worth telling the player about this game's last launch, worst first.
    public static func findings(run: LastRun?, launchOptions: SteamLaunchOptions?, runner: Runner?,
                                settings: GameSettings, detected: Backend? = nil, isUnreal: Bool = false) -> [LaunchFinding] {
        var out: [LaunchFinding] = []

        if runner == nil {
            out.append(.init(severity: .error, title: "The engine is not installed",
                             detail: "WovenGames needs its engine to run Windows games. Install it on the Status page.",
                             fix: .installEngine))
        } else if let runner, settings.backend == .d3dmetal || (settings.backend == .auto && detected == .d3dmetal),
                  !runner.has(.d3dmetal) {
            out.append(.init(severity: .error, title: "D3DMetal is not downloaded",
                             detail: "This game uses Apple's D3DMetal, which WovenGames downloads from Apple when the engine is installed. Reinstall the engine to fetch it.",
                             fix: .installEngine))
        }

        if let options = launchOptions {
            let misplaced = options.misplacedSettings
            if !misplaced.isEmpty {
                out.append(.init(severity: .error, title: "Steam cannot start the game with these launch options",
                                 detail: "\(misplaced.joined(separator: " ")) comes before %command%. On a Mac, Steam then looks for a program with that name and fails (\"OS Error 260\"). Settings belong after %command%; copy the corrected options into the game's Properties → General → Launch Options in Steam.",
                                 fix: .launchOptions(options.corrected),
                                 misplacedSettings: misplaced,
                                 cleanedOptions: options.cleaned))
            }
            let overriding = options.settings.filter { $0.hasPrefix("CX_GRAPHICS_BACKEND=") || $0.hasPrefix("MTL_HUD_ENABLED=") || $0.hasPrefix("WOVEN_RETINA=") }
            if !overriding.isEmpty {
                out.append(.init(severity: .info, title: "Steam's launch options win over this page",
                                 detail: "The game's launch options in Steam set \(overriding.joined(separator: " ")), which takes priority over the settings here.",
                                 fix: nil))
            }
        }

        guard let run else { return out.sorted { $0.severity > $1.severity } }

        if run.foreignPrefix {
            out.append(.init(severity: .error, title: "The game's Windows environment came from another tool",
                             detail: "Its prefix was made by a different Wine build (for example CrossOver or an older WovenGames), and this engine cannot use it. Reset the prefix: saves synced to Steam Cloud come back, and the old prefix goes to the Trash.",
                             fix: .resetPrefix, source: .lastRun))
        } else if let file = run.stagingFailed {
            out.append(.init(severity: .error, title: "Engine files are missing",
                             detail: "WovenGames could not copy \(file) into the game's environment. Reinstalling the engine puts the files back.",
                             fix: .installEngine, source: .lastRun))
        } else if let stage = run.abortedStage {
            let fix: LaunchFinding.Fix = switch stage {
            case "bridge staging": .installEngine
            case "profile layout", "prefix arch check": .resetPrefix
            default: .openLaunchLog
            }
            out.append(.init(severity: .error, title: "WovenGames stopped before starting the game",
                             detail: "Preparing the game failed during \"\(stage)\". \(fix == .resetPrefix ? "Resetting the game's prefix usually fixes this." : fix == .installEngine ? "Reinstalling the engine usually fixes this." : "The launch log has the details.")",
                             fix: fix, source: .lastRun))
        } else if let status = run.exitStatus, status != 0, !run.terminated,
                  // no duration (an older launch script's log): it may have run for hours
                  let seconds = run.seconds, seconds < 30 {
            let next = alternative(to: run.backend, runner: runner)
            let fix: LaunchFinding.Fix?
            let tryText: String?
            if let next {
                if next == .dxmt && isUnreal {
                    fix = .useSettings(backend: .dxmt, gameArgs: "-dx11")
                    tryText = "Games often start with a different graphics backend: try DXMT with -dx11."
                } else {
                    fix = .switchBackend(next)
                    tryText = "Games often start with a different graphics backend: try \(next.label.components(separatedBy: " (").first ?? next.rawValue)."
                }
            } else {
                fix = .openLaunchLog
                tryText = nil
            }
            out.append(.init(severity: .warning, title: "The game closed right after starting",
                             detail: "It ran for \(seconds) seconds and exited with status \(status). \(tryText ?? "The launch log has the details.")",
                             fix: fix, source: .lastRun))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    /// The finding worth a notification when a game quits: the worst problem with the launch
    /// that just ended. Setup findings (engine, launch options) were there before the launch
    /// and are shown on the Games page instead. `findings` comes worst first, as findings() returns it.
    public static func notifiable(_ findings: [LaunchFinding]) -> LaunchFinding? {
        findings.first { $0.source == .lastRun && $0.severity >= .warning }
    }

    /// Another backend worth a try after a crash on `backend`.
    static func alternative(to backend: String?, runner: Runner?) -> GameSettings.BackendChoice? {
        let hasD3DMetal = runner?.has(.d3dmetal) ?? false
        switch backend {
        case "dxmt": return hasD3DMetal ? .d3dmetal : .wined3d
        case "d3dmetal": return .dxmt
        case "wined3d": return .dxmt
        default: return nil
        }
    }
}

// MARK: - GameSettings helpers for launch fixes

extension GameSettings {
    /// Applies misplaced launch option tokens (e.g. `["CX_GRAPHICS_BACKEND=dxmt", "MTL_HUD_ENABLED=1"]`)
    /// into this game's settings. Known keys update typed fields; unknown keys are appended to `otherLines`.
    public mutating func apply(tokens: [String]) {
        for token in tokens {
            let line = token.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard !line.hasPrefix("#"), parts.count == 2, let key = parts.first, !key.isEmpty else {
                if !otherLines.contains(line) { otherLines.append(line) }
                continue
            }
            // the same keys as GameSettings(parsing:); an unknown key replaces its earlier line
            guard !assign(key, parts[1]) else { continue }
            if let idx = otherLines.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
                otherLines[idx] = line
            } else {
                otherLines.append(line)
            }
        }
    }

    /// Sets the backend and appends `gameArgs` if not already present.
    public mutating func apply(backend: BackendChoice, gameArgs arg: String) {
        self.backend = backend
        self.gameArgs = LaunchDiagnosis.addingArg(arg, to: self.gameArgs)
    }
}
