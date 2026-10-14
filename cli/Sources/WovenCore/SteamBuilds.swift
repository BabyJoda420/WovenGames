// Steam build tracking: does the hook work on the Steam build that is installed, on the one
// Steam has downloaded but not applied, and on the newest build Valve has published?
//
// Three sources:
//   - the hook's own log (wovengames.log): what happened the last time Steam started
//   - steam-builds.json: builds checked by engine/scripts/check-steam-build.sh (offline) or
//     played on (live); shipped in compat/, refreshed from GitHub when the repo is public
//   - Valve's CDN manifests: the newest public and beta builds

import Foundation

/// What the hook logged for one Steam session.
public struct HookSession: Equatable, Sendable {
    public struct Count: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var complete: Bool { total > 0 && done == total }
    }

    public var started: Date?
    public var signatures: Count?
    public var hooks: Count?
    public var uiSignatures: Count?
    public var uiHooks: Count?

    /// every count the session logged is complete, and the client part was logged at all
    public var healthy: Bool {
        guard let signatures, let hooks else { return false }
        return [signatures, hooks, uiSignatures, uiHooks].compactMap { $0 }.allSatisfy(\.complete)
            && signatures.complete && hooks.complete
    }

    /// The last session in a hook log.
    public static func last(inLog text: String) -> HookSession? {
        // np_init logs more than once per launch; the session starts at the first of the
        // markers that directly precede the last one with the same pid (pids get reused, so an
        // older session with this pid must not count)
        let marker = try! Regex(#"np_init: loaded into steam_osx \(pid (\d+)\)"#)
        let markers = text.matches(of: marker)
        guard var first = markers.indices.last, let pid = markers[first].output[1].substring else { return nil }
        while first > markers.startIndex, markers[first - 1].output[1].substring == pid,
              !text[markers[first - 1].range.upperBound..<markers[first].range.lowerBound].contains("install_thread") {
            first -= 1
        }
        let sessionStart = text[..<markers[first].range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let session = text[sessionStart...]
        var result = HookSession()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        result.started = stamp.date(from: String(session.prefix(19)))

        func count(_ pattern: String) -> Count? {
            guard let m = session.matches(of: try! Regex(pattern)).last,
                  let a = m.output[1].substring.flatMap({ Int($0) }),
                  let b = m.output[2].substring.flatMap({ Int($0) }) else { return nil }
            return Count(done: a, total: b)
        }
        result.signatures = count(#"install_thread: signatures (\d+)/(\d+) resolved"#)
        result.hooks = count(#"\] info hooks: (\d+)/(\d+) installed"#)
        result.uiSignatures = count(#"steamui\.dylib signatures (\d+)/(\d+) resolved"#)
        result.uiHooks = count(#"hooks: steamui (\d+)/(\d+) installed"#)
        return result
    }
}

/// One entry of steam-builds.json.
public struct CheckedBuild: Codable, Equatable, Sendable {
    public var build: Int
    public var channel: String
    public var signatures: String?
    public var resolved: Int
    public var unresolved: Int
    public var checked: String
    public var live: Bool?
    public var note: String?

    public var works: Bool { unresolved == 0 && resolved > 0 }
}

public struct CheckedBuilds: Codable, Sendable {
    public var builds: [CheckedBuild]

    public func entry(for build: String?) -> CheckedBuild? {
        guard let build, let n = Int(build) else { return nil }
        return builds.first { $0.build == n }
    }

    public static func load(from url: URL) -> CheckedBuilds? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CheckedBuilds.self, from: data)
    }
}

public enum BuildVerdict: Equatable, Sendable {
    /// the hook ran on this build and everything resolved
    case working
    /// the hook ran on this build and some signatures or hooks failed
    case broken(String)
    /// check-steam-build.sh resolved every signature (not played on yet)
    case checkedOffline
    /// check-steam-build.sh found unresolved signatures
    case failsOffline(Int)
    case unchecked

    public var isSafe: Bool {
        switch self {
        case .working, .checkedOffline: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .working: "works"
        case .broken(let why): "broken: \(why)"
        case .checkedOffline: "checked, should work"
        case .failsOffline(let n): "not supported (\(n) signature\(n == 1 ? "" : "s") missing)"
        case .unchecked: "not checked yet"
        }
    }
}

public struct SteamBuildReport: Sendable {
    public var installed: String?
    public var pending: String?
    public var latestPublic: String?
    public var latestBeta: String?
    public var session: HookSession?
    /// the last hook session ran on the installed build (it started after that build was installed)
    public var sessionOnInstalled: Bool
    public var checked: CheckedBuilds

    public func verdict(for build: String?) -> BuildVerdict {
        guard let build else { return .unchecked }
        if build == installed, sessionOnInstalled, let session {
            if session.healthy { return .working }
            let parts = [("signatures", session.signatures), ("hooks", session.hooks),
                         ("Steam UI signatures", session.uiSignatures), ("Steam UI hooks", session.uiHooks)]
                .compactMap { name, c in c.flatMap { $0.complete ? nil : "\(name) \($0.done)/\($0.total)" } }
            return .broken(parts.isEmpty ? "the hook did not finish loading" : parts.joined(separator: ", "))
        }
        if let entry = checked.entry(for: build) {
            if entry.live == true && entry.works { return .working }
            return entry.works ? .checkedOffline : .failsOffline(entry.unresolved)
        }
        return .unchecked
    }
}

public enum SteamBuilds {
    static let cdn = "https://client-update.akamai.steamstatic.com"
    static var remoteDatabase: URL {
        URL(string: "https://raw.githubusercontent.com/\(ReleaseInstaller.repository)/main/compat/steam-builds.json")!
    }

    public static func installedDatabase(paths: Paths = Paths()) -> URL {
        paths.support.appending(path: "compat/steam-builds.json")
    }

    /// Everything that needs no network.
    public static func localReport(paths: Paths = Paths()) -> SteamBuildReport {
        let steam = SteamStatus(paths: paths.steam)
        let log = (try? String(contentsOf: paths.hookLog, encoding: .utf8)).flatMap(HookSession.last(inLog:))
        var onInstalled = false
        if let started = log?.started, let installedAt = SteamStatus.installedManifestDate(packageDir: paths.steam.packageDir) {
            // the log has whole seconds, the manifest's date has fractions
            onInstalled = started >= installedAt.addingTimeInterval(-installedAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1))
        }
        return SteamBuildReport(installed: steam.clientBuild, pending: steam.pendingBuild,
                                latestPublic: nil, latestBeta: nil, session: log, sessionOnInstalled: onInstalled,
                                checked: CheckedBuilds.load(from: installedDatabase(paths: paths)) ?? CheckedBuilds(builds: []))
    }

    /// Adds Valve's newest builds and, when reachable, the newest steam-builds.json from GitHub.
    public static func fullReport(paths: Paths = Paths()) async -> SteamBuildReport {
        var report = localReport(paths: paths)
        async let pub = latest(manifest: "steam_client_osx")
        async let beta = latest(manifest: "steam_client_publicbeta_osx")
        async let remote = remoteChecked()
        report.latestPublic = await pub
        report.latestBeta = await beta
        if let remote = await remote {
            // a newer database knows every build the shipped one knows, and more
            var merged = remote.builds
            for b in report.checked.builds where !merged.contains(where: { $0.build == b.build }) { merged.append(b) }
            report.checked = CheckedBuilds(builds: merged)
        }
        return report
    }

    static func latest(manifest: String) async -> String? {
        guard let url = URL(string: "\(cdn)/\(manifest)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return SteamStatus.manifestVersion(String(decoding: data, as: UTF8.self))
    }

    static func remoteChecked() async -> CheckedBuilds? {
        guard let (data, response) = try? await URLSession.shared.data(from: remoteDatabase),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(CheckedBuilds.self, from: data)
    }
}
