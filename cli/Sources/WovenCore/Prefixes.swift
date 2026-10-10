// Wine prefixes (one per game, like Proton's compatdata)

import Foundation

public enum PrefixError: Error, CustomStringConvertible {
    case badName(String)
    case missing(String)

    public var description: String {
        switch self {
        case .badName(let n): "prefix names may only use letters, digits, '.', '-' and '_': \(n)"
        case .missing(let n): "no prefix named \(n)"
        }
    }
}

public struct Prefixes: Sendable {
    public var paths: Paths

    public init(paths: Paths = Paths()) { self.paths = paths }

    public func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.prefixes.path(percentEncoded: false))) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    public func url(_ name: String) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }), name != ".", name != ".." else {
            throw PrefixError.badName(name)
        }
        return paths.prefix(named: name)
    }

    /// Creates (or updates) a prefix with `wineboot -u`.
    public func create(_ name: String, runner: Runner) throws -> Int32 {
        let launch = WineLaunch(runner: runner, prefix: try url(name), backend: .wined3d)
        let status = try launch.run(["wineboot", "-u"])
        launch.waitForServer()
        return status
    }

    /// Moves a prefix to the Trash, so a mistake can still be undone.
    public func delete(_ name: String) throws {
        let prefix = try url(name)
        guard FileManager.default.fileExists(atPath: prefix.path(percentEncoded: false)) else { throw PrefixError.missing(name) }
        try FileManager.default.trashItem(at: prefix, resultingItemURL: nil)
    }
}
