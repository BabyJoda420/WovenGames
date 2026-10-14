// `woven install`: installs a WovenGames release (engine/scripts/package-release.sh).
//
// A release carries no files of Apple's or Valve's. They are fetched here, on the user's Mac,
// and each one is checked against a pinned SHA-256:
//   - D3DMetal (Apple Game Porting Toolkit 3.0, Gcenx's repack; Apple's licence allows personal,
//     non-commercial use), from release.json
//   - Valve's Windows Steam DLLs, from Valve's CDN, per valve-packages.manifest

import CryptoKit
import Foundation

public enum ReleaseError: Error, CustomStringConvertible {
    case download(String, String)
    case hashMismatch(String)
    case badRelease(String)

    public var description: String {
        switch self {
        case .download(let what, let why): "could not download \(what): \(why)"
        case .hashMismatch(let what): "\(what) does not match its pinned SHA-256; not installing it"
        case .badRelease(let why): "not a WovenGames release: \(why)"
        }
    }
}

public struct ReleaseInfo: Codable, Sendable {
    public struct Pinned: Codable, Sendable {
        public var url: String
        public var sha256: String
    }
    public var version: String
    public var runner: String
    public var commit: String?
    public var built: String?
    public var d3dmetal: Pinned
}

public struct ReleaseInstaller: Sendable {
    public var paths: Paths
    /// downloads are kept here, so a reinstall does not fetch them again
    public var cache: URL

    public init(paths: Paths = Paths()) {
        self.paths = paths
        cache = paths.home.appending(path: "Library/Caches/WovenGames/downloads")
    }

    /// Installs from a release archive (.tar.xz) on disk or at a URL.
    public func install(archive: URL, log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        if RunnerStore(paths: paths).inUse() { throw RunnerError.inUse }
        let local: URL
        if archive.isFileURL {
            local = archive
            if let expected = (try? String(contentsOf: URL(filePath: archive.path(percentEncoded: false) + ".sha256"), encoding: .utf8))
                .flatMap(Self.firstHash) {
                guard Self.sha256(of: local) == expected else { throw ReleaseError.hashMismatch(local.lastPathComponent) }
                log("archive matches its .sha256")
            }
        } else {
            local = cache.appending(path: archive.lastPathComponent)
            // the release publishes <archive>.sha256: verify against it, and reuse a cached copy that matches
            var expected: String?
            if let url = URL(string: archive.absoluteString + ".sha256"),
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                expected = Self.firstHash(String(decoding: data, as: UTF8.self))
            }
            if expected == nil { log("no .sha256 published next to the archive; relying on HTTPS only") }
            log("downloading \(archive.lastPathComponent)...")
            try await download(archive, to: local, sha256: expected)
        }

        let work = cache.appending(path: "unpacked-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/tar", ["-xJf", local.path(percentEncoded: false), "-C", work.path(percentEncoded: false)], "unpacking the release")
        guard let top = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("wovengames-engine-") }),
              let data = try? Data(contentsOf: top.appending(path: "release.json")),
              let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data)
        else { throw ReleaseError.badRelease("no wovengames-engine-*/release.json inside") }
        log("release \(info.version) (\(info.runner))")

        try await addD3DMetal(to: top.appending(path: "runner"), pinned: info.d3dmetal, log: log)
        let valve = work.appending(path: "valve-bridge")
        try await fetchValveBridge(manifest: top.appending(path: "valve-packages.manifest"), into: valve, log: log)

        let support = top.appending(path: "support")
        let payload = Payload(
            runner: top.appending(path: "runner"),
            hook: support.appending(path: "wovengames.dylib"),
            helpers: Dictionary(uniqueKeysWithValues: ["overlay-shim.dylib", "iconmaker", "appinfo", "pe-d3d", "syshud"]
                .map { ($0, support.appending(path: $0)) }),
            signatures: top.appending(path: "signatures"),
            compat: top.appending(path: "compat"),
            valveBridge: valve,
            hookVersion: ((try? String(contentsOf: support.appending(path: "dylib.version"), encoding: .utf8)) ?? info.version)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            hint: "the release archive is incomplete",
            engineVersion: info.version)
        try Setup(paths: paths, payload: payload).run(log: log)
    }

    public static let repository = "BabyJoda420/WovenGames"

    /// The engine archive of the newest GitHub release.
    public static func latestReleaseAsset() async throws -> URL {
        let api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ReleaseError.download("the latest release", "GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0) (no public release yet?)")
        }
        struct Release: Decodable { struct Asset: Decodable { var name: String; var browser_download_url: String }; var assets: [Asset] }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("wovengames-engine-") && $0.name.hasSuffix(".tar.xz") }),
              let url = URL(string: asset.browser_download_url)
        else { throw ReleaseError.badRelease("the latest release has no engine archive") }
        return url
    }

    // MARK: D3DMetal

    /// Lays D3DMetal into a runner the way assemble-runner.sh does.
    func addD3DMetal(to runner: URL, pinned: ReleaseInfo.Pinned, log: (String) -> Void) async throws {
        let fm = FileManager.default
        guard let url = URL(string: pinned.url) else { throw ReleaseError.badRelease("bad D3DMetal URL") }
        let archive = cache.appending(path: url.lastPathComponent)
        log("fetching D3DMetal (Apple Game Porting Toolkit 3.0)...")
        try await download(url, to: archive, sha256: pinned.sha256)

        let work = cache.appending(path: "gptk-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/tar", ["-xJf", archive.path(percentEncoded: false), "-C", work.path(percentEncoded: false)], "unpacking D3DMetal")
        let g = work.appending(path: "Game Porting Toolkit.app/Contents/Resources/wine/lib")
        guard fm.fileExists(atPath: g.appending(path: "external/D3DMetal.framework").path(percentEncoded: false)) else {
            throw ReleaseError.badRelease("the D3DMetal archive has an unexpected layout")
        }
        let external = runner.appending(path: "lib/external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [g.appending(path: "external/D3DMetal.framework").path(percentEncoded: false),
                                   external.appending(path: "D3DMetal.framework").path(percentEncoded: false)], "copying D3DMetal")
        try fm.copyItem(at: g.appending(path: "external/libd3dshared.dylib"), to: external.appending(path: "libd3dshared.dylib"))
        try? fm.copyItem(at: work.appending(path: "Game Porting Toolkit.app/Contents/Resources/License.rtf"),
                         to: external.appending(path: "D3DMetal-License.rtf"))

        let renderer = runner.appending(path: "lib/renderers/d3dmetal")
        try fm.createDirectory(at: renderer.appending(path: "x86_64-windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: renderer.appending(path: "x86_64-unix"), withIntermediateDirectories: true)
        for dll in ["d3d10", "d3d11", "d3d12", "dxgi", "nvapi64", "atidxx64"] {
            try fm.copyItem(at: g.appending(path: "wine/x86_64-windows/\(dll).dll"), to: renderer.appending(path: "x86_64-windows/\(dll).dll"))
            try fm.createSymbolicLink(atPath: renderer.appending(path: "x86_64-unix/\(dll).so").path(percentEncoded: false),
                                      withDestinationPath: "../../../external/libd3dshared.dylib")
        }
        // DLSS -> MetalFX: the MetalFX NGX shim takes nvngx's place
        try fm.copyItem(at: g.appending(path: "wine/x86_64-windows/nvngx-on-metalfx.dll"), to: renderer.appending(path: "x86_64-windows/nvngx.dll"))
        try fm.createSymbolicLink(atPath: renderer.appending(path: "x86_64-unix/nvngx.so").path(percentEncoded: false),
                                  withDestinationPath: "../../../external/libd3dshared.dylib")
        log("D3DMetal added to the runner")
    }

    // MARK: Valve's bridge DLLs

    struct ValveManifest {
        var bases: [String] = []
        var packages: [(id: String, file: String, sha: String)] = []
        var files: [(bridge: String, package: String, inner: String, sha: String)] = []

        init(_ text: String) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let f = raw.split(whereSeparator: \.isWhitespace).map(String.init)
                switch f.first {
                case "base" where f.count >= 2: bases.append(f[1])
                case "package" where f.count >= 4: packages.append((f[1], f[2], f[3]))
                case "file" where f.count >= 5: files.append((f[1], f[2], f[3], f[4]))
                default: break
                }
            }
        }
    }

    /// fetch-valve-bridge.sh in Swift: every package and every file taken out of it is hash-checked.
    func fetchValveBridge(manifest: URL, into out: URL, log: (String) -> Void) async throws {
        let fm = FileManager.default
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { throw ReleaseError.badRelease("no valve-packages.manifest") }
        let m = ValveManifest(text)
        log("fetching Valve's Windows Steam DLLs from Valve's CDN...")
        var unpacked: [String: URL] = [:]
        for pkg in m.packages {
            let dest = cache.appending(path: "valve/\(pkg.file)")
            var lastError: Error?
            for base in m.bases where !fm.fileExists(atPath: dest.path(percentEncoded: false)) || Self.sha256(of: dest) != pkg.sha {
                do {
                    try await download(URL(string: "\(base)/\(pkg.file)")!, to: dest, sha256: pkg.sha)
                    lastError = nil
                    break
                } catch { lastError = error }
            }
            if let lastError { throw lastError }
            let dir = cache.appending(path: "valve/x-\(pkg.id)")
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // the Linux package carries backslash-named symlinks unzip may refuse; the files used are hash-checked below
            _ = Shell.capture("/usr/bin/unzip", ["-q", "-o", dest.path(percentEncoded: false), "-d", dir.path(percentEncoded: false)])
            unpacked[pkg.id] = dir
        }
        for file in m.files {
            guard let dir = unpacked[file.package] else { throw ReleaseError.badRelease("unknown package \(file.package)") }
            let src = dir.appending(path: file.inner)
            guard Self.sha256(of: src) == file.sha else { throw ReleaseError.hashMismatch(file.inner) }
            let dest = out.appending(path: file.bridge)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
        }
        log("Valve bridge: \(m.files.count) files verified")
    }

    // MARK: helpers

    func download(_ url: URL, to dest: URL, sha256: String?) async throws {
        let fm = FileManager.default
        if let sha256, Self.sha256(of: dest) == sha256 { return }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? fm.removeItem(at: tmp)
            throw ReleaseError.download(url.lastPathComponent, "HTTP \(http.statusCode)")
        }
        if let sha256, Self.sha256(of: tmp) != sha256 {
            try? fm.removeItem(at: tmp)
            throw ReleaseError.hashMismatch(url.lastPathComponent)
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
    }

    func run(_ tool: String, _ args: [String], _ what: String) throws {
        let r = Shell.capture(tool, args)
        guard r.status == 0 else { throw ReleaseError.badRelease("\(what) failed: \(r.output.suffix(400))") }
    }

    /// The first 64-hex-digit word of a `shasum -a 256` line.
    static func firstHash(_ text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
            .first { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
