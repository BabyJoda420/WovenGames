// Installed Steam games, and what WovenGames last did with each

import Foundation

public struct InstalledGame: Identifiable, Hashable, Sendable {
    public var appID: String
    public var name: String
    public var installDir: URL
    /// steamapps/compatdata/<appid>: present once the game has run under a compat tool
    public var compatData: URL
    public var sizeOnDisk: Int64

    public var id: String { appID }
    public var prefix: URL { compatData.appending(path: "pfx") }
    public var runLog: URL { compatData.appending(path: "wovengames-run.log") }
}

public struct LastRun: Equatable, Sendable {
    public var date: String?
    /// "dxmt", "d3dmetal", "wined3d"
    public var backend: String?
    /// why, e.g. "auto (d3d11)" or "launch-options"
    public var backendReason: String?
    /// the last "=== aborted ..." or "=== ... missing ..." line, if any
    public var problem: String?
}

public struct SteamLibrary: Sendable {
    public var paths: Paths

    public init(paths: Paths = Paths()) { self.paths = paths }

    /// Steam installs these like games, but they only hold installers other games use
    /// (228980: Steamworks Common Redistributables, full of Windows .exe files).
    static let notGames: Set<String> = ["228980"]

    /// Every library folder Steam knows (libraryfolders.vdf), the default one first.
    public func folders() -> [URL] {
        var out = [paths.steam.userData]
        let vdf = paths.steam.userData.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            let root = VDF.parse(text)["libraryfolders"] ?? .object([])
            for (_, folder) in root.pairs {
                guard let path = folder["path"]?.string else { continue }
                let url = URL(filePath: path).standardizedFileURL
                if !out.contains(where: { $0.standardizedFileURL == url }) { out.append(url) }
            }
        }
        return out
    }

    /// Installed games that look like Windows games (an .exe in their install folder).
    public func windowsGames() -> [InstalledGame] {
        let fm = FileManager.default
        var games: [InstalledGame] = []
        for folder in folders() {
            let steamapps = folder.appending(path: "steamapps")
            let manifests = ((try? fm.contentsOfDirectory(atPath: steamapps.path(percentEncoded: false))) ?? [])
                .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
            for file in manifests {
                guard let text = try? String(contentsOf: steamapps.appending(path: file), encoding: .utf8),
                      let state = VDF.parse(text)["AppState"],
                      let appID = state["appid"]?.string,
                      let name = state["name"]?.string,
                      let dir = state["installdir"]?.string,
                      !Self.notGames.contains(appID)
                else { continue }
                let installDir = steamapps.appending(path: "common/\(dir)")
                let compatData = steamapps.appending(path: "compatdata/\(appID)")
                // a game that already ran under a compat tool counts even mid-update
                let ranBefore = fm.fileExists(atPath: compatData.appending(path: "pfx").path(percentEncoded: false))
                guard ranBefore || Self.hasWindowsExecutable(installDir) else { continue }
                games.append(InstalledGame(
                    appID: appID, name: name, installDir: installDir,
                    compatData: compatData,
                    sizeOnDisk: Int64(state["SizeOnDisk"]?.string ?? "") ?? 0))
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func hasWindowsExecutable(_ dir: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker {
            if walker.level > 5 { walker.skipDescendants(); continue }  // UE: Game/Binaries/Win64/x.exe
            if url.pathExtension.lowercased() == "exe" { return true }
        }
        return false
    }

    /// What the compat tool's run log says about the most recent launch.
    public static func lastRun(of game: InstalledGame) -> LastRun? {
        guard let text = try? String(contentsOf: game.runLog, encoding: .utf8) else { return nil }
        return lastRun(log: text)
    }

    static func lastRun(log text: String) -> LastRun? {
        guard let start = text.range(of: "=== wovengames run ", options: .backwards) else { return nil }
        let run = text[start.lowerBound...]
        var result = LastRun()
        for line in run.split(separator: "\n") {
            if line.hasPrefix("=== wovengames run ") {
                result.date = String(line.dropFirst("=== wovengames run ".count).dropLast(4))
            } else if line.hasPrefix("graphics: ") {
                let rest = line.dropFirst("graphics: ".count)
                let parts = rest.components(separatedBy: " from ")
                result.backend = parts.first
                result.backendReason = parts.count > 1 ? parts[1] : nil
            } else if line.hasPrefix("=== aborted") || line.contains("missing") && line.hasPrefix("===") {
                result.problem = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
            }
        }
        return result
    }
}
