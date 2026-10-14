import ArgumentParser
import Foundation
import WovenCore

// MARK: - snapshot

extension Woven {
    struct SnapshotCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "snapshot",
            abstract: "Snapshots of a game's prefix (instant APFS clones).",
            subcommands: [List.self, Take.self, Restore.self, Delete.self]
        )

        static func snapshots(_ appID: String) throws -> PrefixSnapshots {
            PrefixSnapshots(compatData: try GamesCommand.game(appID).compatData)
        }

        static func refuseWhileRunning(_ appID: String) throws {
            if GameSessions().running().contains(appID) { throw SnapshotError.gameRunning }
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List a game's snapshots, newest first.")
            @Argument(help: "The game's Steam app id.") var appID: String

            func run() throws {
                let all = try SnapshotCommand.snapshots(appID).list()
                if all.isEmpty { print("no snapshots"); return }
                for s in all { print("\(s.id)\(s.automatic ? "  (before an engine update)" : "")") }
            }
        }

        struct Take: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Take a snapshot of a game's prefix.")
            @Argument(help: "The game's Steam app id.") var appID: String

            func run() throws {
                try SnapshotCommand.refuseWhileRunning(appID)
                print(try SnapshotCommand.snapshots(appID).take().id)
            }
        }

        struct Restore: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Put a snapshot back. The current prefix goes to the Trash.")
            @Argument(help: "The game's Steam app id.") var appID: String
            @Argument(help: "The snapshot (see `woven snapshot list`).") var id: String

            func run() throws {
                try SnapshotCommand.refuseWhileRunning(appID)
                try SnapshotCommand.snapshots(appID).restore(id)
                print("restored \(id); the previous prefix is in the Trash")
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Delete a snapshot.")
            @Argument(help: "The game's Steam app id.") var appID: String
            @Argument(help: "The snapshot (see `woven snapshot list`).") var id: String

            func run() throws {
                try SnapshotCommand.snapshots(appID).delete(id)
            }
        }
    }
}
