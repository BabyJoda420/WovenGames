// New WovenGames releases on GitHub, and getting them onto this Mac.
//
// A release carries the engine (wovengames-engine-<v>.tar.xz) and the app
// (WovenGames-<v>.zip), each with a .sha256 beside it. Betas are GitHub pre-releases: only
// offered when the user asks for them.

import Foundation

/// A version like 0.2.0 or 0.2.0-beta.1, compared the semver way (a beta sorts before its release).
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public var numbers: [Int]
    /// "beta.1"; nil for a release
    public var prerelease: String?

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.map { $0! }
        prerelease = parts.count > 1 ? parts[1] : nil
    }

    public var isPrerelease: Bool { prerelease != nil }
    public var description: String { numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "") }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: Version, b: Version) -> Bool {
        let n = max(a.numbers.count, b.numbers.count)
        for i in 0..<n {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return comparePre(x, y)
        }
    }

    /// beta.2 < beta.10, alpha < beta: dot-separated, numeric parts compared as numbers
    static func comparePre(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "."), y = b.split(separator: ".")
        for (p, q) in zip(x, y) where p != q {
            switch (Int(p), Int(q)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            default: return p < q
            }
        }
        return x.count < y.count
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public var name: String
        public var browser_download_url: String
        public var size: Int
    }

    public var tag_name: String
    public var name: String?
    public var prerelease: Bool
    public var draft: Bool
    public var html_url: String
    public var body: String?
    public var assets: [Asset]

    public var version: Version? { Version(tag_name) }

    public func asset(prefix: String, suffix: String) -> URL? {
        assets.first { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(suffix) }
            .flatMap { URL(string: $0.browser_download_url) }
    }

    public var engineArchive: URL? { asset(prefix: "wovengames-engine-", suffix: ".tar.xz") }
    public var appArchive: URL? { asset(prefix: "WovenGames-", suffix: ".zip") }
}

public struct UpdateCheck: Sendable {
    public var current: Version
    public var includeBetas: Bool
    public var api = URL(string: "https://api.github.com/repos/\(ReleaseInstaller.repository)/releases?per_page=20")!

    public init(current: Version, includeBetas: Bool) {
        self.current = current
        self.includeBetas = includeBetas
    }

    /// The newest release this Mac should be offered, if it is newer than `current`.
    public func newer(session: URLSession = .shared) async throws -> GitHubRelease? {
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ReleaseError.download("the release list", "GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return pick(from: try JSONDecoder().decode([GitHubRelease].self, from: data))
    }

    func pick(from releases: [GitHubRelease]) -> GitHubRelease? {
        let candidates = releases.filter { r in
            !r.draft && r.engineArchive != nil && r.version != nil && (includeBetas || !r.prerelease)
        }
        guard let best = candidates.max(by: { $0.version! < $1.version! }), best.version! > current else { return nil }
        return best
    }
}

public enum AppUpdate {
    /// Downloads a release's app, checks it against its .sha256, and unpacks it into `staging`.
    /// Returns the new WovenGames.app; replacing the running app is up to the caller.
    public static func download(_ release: GitHubRelease, staging: URL, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard let zip = release.appArchive else { throw ReleaseError.badRelease("\(release.tag_name) has no app download") }
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let shaURL = URL(string: zip.absoluteString + ".sha256") else { throw ReleaseError.badRelease("bad download link") }
        let (shaData, shaResponse) = try await URLSession.shared.data(from: shaURL)
        guard (shaResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = ReleaseInstaller.firstHash(String(decoding: shaData, as: UTF8.self)) else {
            throw ReleaseError.badRelease("\(zip.lastPathComponent) has no published checksum; not installing it")
        }
        log("downloading \(zip.lastPathComponent)...")
        let (temp, response) = try await URLSession.shared.download(from: zip)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ReleaseError.download(zip.lastPathComponent, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let local = staging.appending(path: zip.lastPathComponent)
        try fm.moveItem(at: temp, to: local)
        guard ReleaseInstaller.sha256(of: local) == expected else { throw ReleaseError.hashMismatch(zip.lastPathComponent) }
        log("checksum matches")
        let unpacked = staging.appending(path: "unpacked")
        let r = Shell.capture("/usr/bin/ditto", ["-x", "-k", local.path(percentEncoded: false), unpacked.path(percentEncoded: false)])
        guard r.status == 0 else { throw ReleaseError.badRelease("could not unpack \(zip.lastPathComponent): \(r.output)") }
        let app = unpacked.appending(path: "WovenGames.app")
        guard fm.fileExists(atPath: app.appending(path: "Contents/Info.plist").path(percentEncoded: false)) else {
            throw ReleaseError.badRelease("\(zip.lastPathComponent) does not contain WovenGames.app")
        }
        let plist = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        guard plist?["CFBundleIdentifier"] as? String == "io.github.babyjoda420.wovengames" else {
            throw ReleaseError.badRelease("the downloaded app is not WovenGames")
        }
        return app
    }
}
