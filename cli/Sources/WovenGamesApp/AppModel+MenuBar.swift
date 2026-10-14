// What the menu bar menu lists: games playing now and games to start

import Foundation
import SwiftUI
import WovenCore

extension AppModel {
    /// Lets a notification, the Dock or the menu bar bring the main window back after it was
    /// closed. The Dock icon comes back first, so the window opens in front.
    func setMainWindowOpener(_ openWindow: OpenWindowAction) {
        openMainWindow = {
            AppDelegate.showInDock()
            openWindow(id: "main")
        }
    }

    /// Installed games running now, by name.
    var menuBarRunningGames: [InstalledGame] {
        games.filter { runningGames.contains($0.appID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Up to `limit` games not running now: most recently played first (by when their run log
    /// was last written), then games never played, by name.
    func menuBarRecentGames(limit: Int = 5) -> [InstalledGame] {
        _ = generation  // re-read after a refresh or a game quitting: the run logs change then
        let candidates = games.filter { !runningGames.contains($0.appID) }
        let played: [String: Date] = Dictionary(uniqueKeysWithValues: candidates.compactMap { game in
            let attributes = try? FileManager.default.attributesOfItem(atPath: game.runLog.path(percentEncoded: false))
            return (attributes?[.modificationDate] as? Date).map { (game.appID, $0) }
        })
        return candidates.sorted { a, b in
            switch (played[a.appID], played[b.appID]) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        .prefix(limit)
        .map { $0 }
    }

    /// "Playing <name> · <backend>", the backend from the game's last run when it is known.
    func menuBarPlayingTitle(_ game: InstalledGame) -> String {
        let backend = SteamLibrary.lastRun(of: game)?.backend.map(Self.backendDisplayName)
        return ["Playing \(game.name)", backend].compactMap { $0 }.joined(separator: " · ")
    }

    /// "dxmt" → "DXMT", "d3dmetal" → "D3DMetal" (as on the Games page)
    nonisolated static func backendDisplayName(_ raw: String) -> String {
        GameSettings.BackendChoice(rawValue: raw)?.label.components(separatedBy: " (").first ?? raw.uppercased()
    }
}
