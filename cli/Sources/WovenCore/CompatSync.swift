// Live game recommendations: compat/<appid>.env files from GitHub's main branch.
//
// Releases ship compat/ too, but a fix for one game (say "-dx11 on DXMT") should not wait for
// a release. The app syncs the folder at most every few hours. Only setting names that tune
// graphics and Wine are kept: the file comes from the network, and the launch script exports
// what it reads.

import CryptoKit
import Foundation

public struct CompatSync: Sendable {
    public var paths: Paths
    /// GitHub's contents API for compat/ (overridable in tests)
    public var listing = URL(string: "https://api.github.com/repos/\(ReleaseInstaller.repository)/contents/compat?ref=main")!
    public var minimumInterval: TimeInterval = 6 * 3600

    public init(paths: Paths = Paths()) { self.paths = paths }

    var folder: URL { paths.support.appending(path: "compat") }
    var stateFile: URL { folder.appending(path: ".sync.json") }

    struct State: Codable {
        var checked: Date?
        /// file name -> what this sync wrote, for the files it manages
        var files: [String: Synced] = [:]
    }

    struct Synced: Codable, Equatable {
        /// git blob sha of the file on GitHub
        var upstream: String
        /// git blob sha of what was written (sanitized), to notice when something replaced it
        var local: String
    }

    struct Entry: Decodable {
        var name: String
        var sha: String
        var size: Int
        var type: String
        var download_url: String?
    }

    public struct Result: Equatable, Sendable {
        public var updated: [String] = []
        public var removed: [String] = []
        public var skipped = false
    }

    /// Setting names a synced file may set. The launch script accepts more (WINEDLLPATH, ...),
    /// which a recommendation never needs.
    static func allowed(_ key: String) -> Bool {
        let exact: Set = ["CX_GRAPHICS_BACKEND", "WINEMSYNC", "WINEESYNC", "WINEDLLOVERRIDES", "WINEDEBUG"]
        let prefixes = ["WOVEN_", "D3DM_", "DXMT_", "MTL_", "ROSETTA_"]
        return exact.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    /// Comments and allowed KEY=VALUE lines; everything else is dropped.
    static func sanitize(_ text: String) -> (text: String, dropped: [String]) {
        var kept: [String] = []
        var dropped: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { kept.append(line); continue }
            let key = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let validName = !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
            if line.contains("=") && validName && allowed(key) { kept.append(line) } else { dropped.append(line) }
        }
        return (kept.joined(separator: "\n") + "\n", dropped)
    }

    static func gitBlobSHA(_ data: Data) -> String {
        var blob = Data("blob \(data.count)\u{0}".utf8)
        blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    func loadState() -> State {
        guard let data = try? Data(contentsOf: stateFile) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    func save(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    /// Fetches what changed upstream. `force` ignores the interval (the CLI, a manual refresh).
    @discardableResult
    public func run(force: Bool = false, session: URLSession = .shared, log: @Sendable (String) -> Void = { _ in }) async throws -> Result {
        var state = loadState()
        if !force, let checked = state.checked, Date().timeIntervalSince(checked) < minimumInterval {
            return Result(skipped: true)
        }
        var request = URLRequest(url: listing)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ReleaseError.download("the game recommendations", "GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" && $0.size <= 16_384 && $0.name.wholeMatch(of: try! Regex(#"\d+\.env"#)) != nil }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var result = Result()
        for entry in entries {
            let local = folder.appending(path: entry.name)
            // already the same content: nothing to download
            let have = (try? Data(contentsOf: local)).map(Self.gitBlobSHA)
            if have == entry.sha { state.files[entry.name] = Synced(upstream: entry.sha, local: entry.sha); continue }
            if let synced = state.files[entry.name], synced.upstream == entry.sha, synced.local == have { continue }
            guard let link = entry.download_url.flatMap(URL.init(string:)) else { continue }
            let (body, reply) = try await session.data(from: link)
            guard (reply as? HTTPURLResponse)?.statusCode == 200, Self.gitBlobSHA(body) == entry.sha else {
                log("\(entry.name): download did not match GitHub's listing, skipped")
                continue
            }
            let clean = Self.sanitize(String(decoding: body, as: UTF8.self))
            for line in clean.dropped { log("\(entry.name): ignored \"\(line)\"") }
            try clean.text.write(to: local, atomically: true, encoding: .utf8)
            state.files[entry.name] = Synced(upstream: entry.sha, local: Self.gitBlobSHA(Data(clean.text.utf8)))
            result.updated.append(entry.name)
        }
        // recommendations withdrawn upstream go away, but only ones this sync wrote
        let upstream = Set(entries.map(\.name))
        for name in state.files.keys.sorted() where !upstream.contains(name) {
            let local = folder.appending(path: name)
            // something else replaced it since (an engine reinstall, the user): not ours to delete
            if let have = (try? Data(contentsOf: local)).map(Self.gitBlobSHA), have != state.files[name]?.local {
                state.files[name] = nil
                continue
            }
            try? fm.removeItem(at: local)
            state.files[name] = nil
            result.removed.append(name)
        }
        state.checked = Date()
        try save(state)
        if !result.updated.isEmpty { log("updated recommendations: \(result.updated.joined(separator: ", "))") }
        if !result.removed.isEmpty { log("withdrawn recommendations: \(result.removed.joined(separator: ", "))") }
        return result
    }
}
