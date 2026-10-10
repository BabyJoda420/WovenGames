// What state macOS Steam is in (read-only; patching it is M3)

import Foundation

public struct SteamStatus: Sendable {
    public enum Injection: Equatable, Sendable {
        case none
        case wovenGames
        case notProton
        case other(String)
    }

    public enum UpdatePin: Equatable, Sendable {
        case none
        /// BootStrapperInhibitAll: the client never updates
        case full
        /// BootStrapperInhibitUpdateOnLaunch only: updates still come in while running
        case onLaunchOnly
    }

    public var installed: Bool
    /// The installed client build (the active `<variant>.manifest`)
    public var clientBuild: String?
    /// A newer build Steam has downloaded but not applied yet (the bare `<variant>` file)
    public var pendingBuild: String?
    public var injection: Injection
    public var pin: UpdatePin
    public var running: Bool

    public init(paths: SteamPaths) {
        let fm = FileManager.default
        installed = fm.fileExists(atPath: paths.app.path(percentEncoded: false))
        (clientBuild, pendingBuild) = Self.builds(packageDir: paths.packageDir)
        injection = Self.injection(infoPlist: paths.infoPlist)
        pin = [paths.configFile, paths.innerClient.appending(path: "steam.cfg")]
            .map(Self.pin(config:))
            .max { $0.rank < $1.rank } ?? .none
        running = Shell.capture("/usr/bin/pgrep", ["-x", "steam_osx"]).status == 0
    }

    /// The installed build is the "version" of the newest `<variant>.manifest` in the client's
    /// package folder; a bare `<variant>` file beside it is a manifest downloaded but not applied.
    static func builds(packageDir: URL) -> (installed: String?, pending: String?) {
        let fm = FileManager.default
        let manifests = ((try? fm.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "manifest" }
        let newest = manifests.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        guard let newest else { return (nil, nil) }
        let installed = (try? String(contentsOf: newest, encoding: .utf8)).flatMap(manifestVersion)
        let pending = (try? String(contentsOf: newest.deletingPathExtension(), encoding: .utf8)).flatMap(manifestVersion)
        return (installed, pending == installed ? nil : pending)
    }

    static func manifestVersion(_ text: String) -> String? {
        let pattern = try! Regex(#""version"\s+"(\d+)""#)
        guard let match = text.firstMatch(of: pattern), let build = match.output[1].substring else { return nil }
        return String(build)
    }

    static func injection(infoPlist: URL) -> Injection {
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = plist["LSEnvironment"] as? [String: Any],
              let insert = env["DYLD_INSERT_LIBRARIES"] as? String, !insert.isEmpty
        else { return .none }
        if insert.contains("wovengames.dylib") { return .wovenGames }
        if insert.contains("notproton.dylib") { return .notProton }
        return .other(insert)
    }

    static func pin(config: URL) -> UpdatePin {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return .none }
        let lines = text.lowercased().split(whereSeparator: \.isNewline).map { $0.replacingOccurrences(of: " ", with: "") }
        if lines.contains("bootstrapperinhibitall=enable") { return .full }
        if lines.contains("bootstrapperinhibitupdateonlaunch=enable") { return .onLaunchOnly }
        return .none
    }
}

extension SteamStatus.UpdatePin {
    var rank: Int {
        switch self {
        case .none: 0
        case .onLaunchOnly: 1
        case .full: 2
        }
    }
}
