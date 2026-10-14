// Wine runners: built by engine/, installed under ~/Library/Application Support/WovenGames/runners

import Foundation

public struct RunnerManifest: Codable, Sendable {
    public var id: String
    public var kind: String
    public var arch: String?
    public var wine: String?
    public var base: String?
    public var renderers: [String: String]?
    public var built: String?
}

public struct Runner: Sendable {
    public var root: URL
    public var manifest: RunnerManifest

    public init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appending(path: "runner.json"))
        manifest = try JSONDecoder().decode(RunnerManifest.self, from: data)
    }

    public var id: String { manifest.id }
    public var wineUnix: URL { root.appending(path: "lib/wine/x86_64-unix") }
    public var loader: URL { wineUnix.appending(path: "wine") }
    public var server: URL { root.appending(path: "bin/wineserver") }
    public var lib: URL { root.appending(path: "lib") }
    public var d3dShared: URL { root.appending(path: "lib/external/libd3dshared.dylib") }

    public func has(_ backend: Backend) -> Bool {
        guard let dir = backend.rendererDir else { return true }
        return FileManager.default.fileExists(atPath: root.appending(path: dir).path(percentEncoded: false))
    }
}

public enum RunnerError: Error, CustomStringConvertible {
    case notARunner(URL)
    case unknown(String)
    case noCurrent
    case inUse

    public var description: String {
        switch self {
        case .notARunner(let url): "\(url.path(percentEncoded: false)) has no runner.json"
        case .unknown(let id): "no installed runner named \(id) (see `woven runner list`)"
        case .noCurrent: "no runner selected; build one (engine/scripts/build-all.sh), then `woven runner install`"
        case .inUse: "a game is running on WovenGames; quit it first (replacing the engine under a running game crashes it)"
        }
    }
}

public struct RunnerStore: Sendable {
    public var paths: Paths

    public init(paths: Paths = Paths()) { self.paths = paths }

    /// True while any Wine process runs from an installed runner (a game, or `woven run`).
    public func inUse() -> Bool {
        Shell.capture("/usr/bin/pgrep", ["-f", paths.runners.path(percentEncoded: false) + "/"]).status == 0
    }

    public func list() -> [Runner] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.runners.path(percentEncoded: false))) ?? []
        return names.filter { $0 != "current" && !$0.hasPrefix(".") }.sorted()
            .compactMap { try? Runner(root: paths.runners.appending(path: $0)) }
    }

    /// The runner a game starts on: its own WOVEN_RUNNER when that is installed, else the
    /// current one (the run script falls back the same way).
    public func runner(for settings: GameSettings) -> Runner? {
        let id = settings.runner
        if !id.isEmpty, id != "current", !id.hasPrefix("."), !id.contains("/"),
           let own = try? Runner(root: paths.runners.appending(path: id)) {
            return own
        }
        return try? current()
    }

    public func current() throws -> Runner {
        let link = paths.currentRunner.path(percentEncoded: false)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            throw RunnerError.noCurrent
        }
        return try Runner(root: paths.runners.appending(path: target))
    }

    /// Copies (or, with `link`, symlinks) a built runner into the store and selects it.
    @discardableResult
    public func install(from source: URL, link: Bool = false) throws -> Runner {
        let built = try Runner(root: source)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.runners, withIntermediateDirectories: true)
        let dest = paths.runners.appending(path: built.id)
        // build the new copy next to the old one, then swap: a failed copy keeps the old runner
        let staging = paths.runners.appending(path: ".\(built.id).new")
        try? fm.removeItem(at: staging)
        if link {
            try fm.createSymbolicLink(at: staging, withDestinationURL: source.standardizedFileURL)
        } else {
            // ditto keeps symlinks, permissions and code signatures intact
            let r = Shell.capture("/usr/bin/ditto", [source.path(percentEncoded: false), staging.path(percentEncoded: false)])
            guard r.status == 0 else {
                try? fm.removeItem(at: staging)
                throw RunnerError.notARunner(source)
            }
        }
        if fm.fileExists(atPath: dest.path(percentEncoded: false)) || (try? fm.destinationOfSymbolicLink(atPath: dest.path(percentEncoded: false))) != nil {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: staging, to: dest)
        try use(built.id)
        return try Runner(root: dest)
    }

    public func use(_ id: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.runners.appending(path: id).appending(path: "runner.json").path(percentEncoded: false)) else {
            throw RunnerError.unknown(id)
        }
        let link = paths.currentRunner
        try? fm.removeItem(at: link)
        // relative, so the store can move as a whole
        try fm.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: id)
    }
}
