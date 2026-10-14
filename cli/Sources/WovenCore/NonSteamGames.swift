// Non-Steam Windows games added to WovenGames: ~/Library/Application Support/WovenGames/nonsteam/
//
// Each non-Steam game gets a unique numeric ID starting with "9" (e.g. 9000000001) that is
// never reused. Its Wine prefix and runtime files live in nonsteam/<id>, so it uses the same
// compat_run.sh, settings, sessions, diagnosis and snapshot lifecycle as Steam games.

import Foundation

public struct NonSteamGame: Codable, Equatable, Sendable, Identifiable {
    /// "9000000001", "9000000002", ... never reused
    public var id: String
    public var name: String
    /// absolute macOS path to the .exe
    public var exe: String
    public var args: [String]

    public init(id: String, name: String, exe: String, args: [String] = []) {
        self.id = id
        self.name = name
        self.exe = exe
        self.args = args
    }
}

public enum NonSteamError: Error, CustomStringConvertible, Sendable, Equatable {
    case notAnExe(URL)
    case fileNotFound(URL)
    case unknown(String)

    public var description: String {
        switch self {
        case .notAnExe(let url): "'\(url.lastPathComponent)' is not a Windows executable (.exe)"
        case .fileNotFound(let url): "file not found at \(url.path(percentEncoded: false))"
        case .unknown(let id): "no non-Steam game with ID \(id)"
        }
    }
}

public struct NonSteamGames: Sendable {
    public var paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    /// <support>/nonsteam
    public var folder: URL { paths.support.appending(path: "nonsteam") }

    /// <support>/nonsteam/games.json
    public var file: URL { folder.appending(path: "games.json") }

    struct Manifest: Codable {
        var nextID: Int64
        var games: [NonSteamGame]

        init(nextID: Int64 = 9000000001, games: [NonSteamGame] = []) {
            self.nextID = nextID
            self.games = games
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.nextID = try container.decodeIfPresent(Int64.self, forKey: .nextID) ?? 9000000001
            self.games = try container.decodeIfPresent([NonSteamGame].self, forKey: .games) ?? []
        }
    }

    /// A missing file is an empty library; a damaged one throws, so a write can't replace it
    /// with an empty list.
    private func loadManifest() throws -> Manifest {
        guard let data = try? Data(contentsOf: file) else { return Manifest() }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func saveManifest(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// List all non-Steam games, sorted by name.
    public func list() -> [NonSteamGame] {
        ((try? loadManifest())?.games ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds a Windows executable (.exe) to the library.
    @discardableResult
    public func add(exe: URL, name: String? = nil, args: [String] = []) throws -> NonSteamGame {
        guard exe.pathExtension.lowercased() == "exe" else {
            throw NonSteamError.notAnExe(exe)
        }
        let stdExe = exe.standardizedFileURL
        let path = stdExe.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            throw NonSteamError.fileNotFound(stdExe)
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespaces)
        let gameName = (trimmedName != nil && !trimmedName!.isEmpty) ? trimmedName! : stdExe.deletingPathExtension().lastPathComponent

        var manifest = try loadManifest()
        let id = String(manifest.nextID)
        manifest.nextID += 1

        let game = NonSteamGame(id: id, name: gameName, exe: path, args: args)
        manifest.games.append(game)
        try saveManifest(manifest)
        return game
    }

    /// Removes a non-Steam game from the library. If deleteData is true, also deletes its compatdata prefix.
    public func remove(id: String, deleteData: Bool = false) throws {
        var manifest = try loadManifest()
        guard let idx = manifest.games.firstIndex(where: { $0.id == id }) else {
            throw NonSteamError.unknown(id)
        }
        manifest.games.remove(at: idx)
        try saveManifest(manifest)

        if deleteData {
            let dataDir = compatData(id: id)
            if FileManager.default.fileExists(atPath: dataDir.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: dataDir)
            }
        }
    }

    /// <support>/nonsteam/<id> (prefix is .../pfx)
    public func compatData(id: String) -> URL {
        folder.appending(path: id)
    }

    /// Formats non-Steam games as InstalledGame instances for unified display and launch.
    public func installedGames() -> [InstalledGame] {
        list().map { game in
            let exeURL = URL(filePath: game.exe)
            let installDir = exeURL.deletingLastPathComponent()
            return InstalledGame(
                appID: game.id,
                name: game.name,
                installDir: installDir,
                compatData: compatData(id: game.id),
                sizeOnDisk: 0
            )
        }
    }

    /// Whether an app ID belongs to a non-Steam game (10 digits starting with "9").
    public static func isNonSteam(appID: String) -> Bool {
        appID.count == 10 && appID.hasPrefix("9") && appID.allSatisfy(\.isNumber)
    }
}
