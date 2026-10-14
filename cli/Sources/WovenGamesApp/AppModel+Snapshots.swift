import Foundation
import WovenCore

// Prefix snapshots from the game page (PrefixSnapshots does the work)
extension AppModel {
    func snapshotPrefix(of game: InstalledGame) async {
        await perform("Snapshot of \(game.name)") { log in
            let snapshot = try PrefixSnapshots(compatData: game.compatData).take()
            log("snapshot \(snapshot.id) of \(game.name)'s prefix")
        }
    }

    func restoreSnapshot(_ id: String, of game: InstalledGame) async {
        guard !runningGames.contains(game.appID) else {
            error = "Quit \(game.name) before restoring a snapshot."
            return
        }
        await perform("Restoring \(game.name)") { log in
            try PrefixSnapshots(compatData: game.compatData).restore(id)
            log("restored \(game.name)'s prefix from \(id); the one it replaced is in the Trash")
        }
    }
}
