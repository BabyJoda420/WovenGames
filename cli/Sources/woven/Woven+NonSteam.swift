import ArgumentParser
import Foundation
import WovenCore

extension Woven.GamesCommand {
    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a Windows executable (.exe) to the games library."
        )

        @Argument(help: "Path to the Windows executable (.exe).")
        var exe: String

        @Option(name: .shortAndLong, help: "Display name for the game.")
        var name: String?

        @Argument(parsing: .postTerminator, help: "Arguments for the game, after --  (e.g. -- -windowed).")
        var args: [String] = []

        func run() throws {
            let exeURL = URL(filePath: NSString(string: exe).expandingTildeInPath,
                             relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL
            let game = try NonSteamGames().add(exe: exeURL, name: name, args: args)
            print("added \(game.name) (\(game.id))")
        }
    }

    struct Play: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a game added outside Steam (Steam games start from Steam)."
        )

        @Argument(help: "The game's app id (see `woven games`).")
        var appID: String

        func run() throws {
            guard let game = NonSteamGames().list().first(where: { $0.id == appID }) else {
                throw NonSteamError.unknown(appID)
            }
            try NonSteamLaunch(game: game).start()
            print("started \(game.name); log: \(NonSteamGames().compatData(id: appID).appending(path: "wovengames-run.log").path(percentEncoded: false))")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a non-Steam game from the library."
        )

        @Argument(help: "The game's app id (see `woven games`).")
        var appID: String

        @Flag(name: .long, help: "Also delete the game's Wine prefix and runtime data.")
        var deleteData = false

        func run() throws {
            try NonSteamGames().remove(id: appID, deleteData: deleteData)
            print("removed \(appID)\(deleteData ? " (and its data)" : "")")
        }
    }
}
