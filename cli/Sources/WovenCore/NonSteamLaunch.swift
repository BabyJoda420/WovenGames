// Starts a game added outside Steam the way Steam starts one: through the compat tool's run
// script, so it gets the same backend choice, settings, launcher bundle (Game Mode), log and
// session tracking. WOVEN_NO_STEAM=1 makes the script skip the steam.exe shim.

import Foundation

public enum NonSteamLaunchError: Error, CustomStringConvertible {
    case noCompatTool
    case oldCompatTool
    case missingExe(String)

    public var description: String {
        switch self {
        case .noCompatTool: "WovenGames is not set up in Steam yet; install the engine and patch Steam first"
        case .oldCompatTool: "the installed compat tool is too old to start games outside Steam; reinstall the engine"
        case .missingExe(let path): "the game's exe is gone: \(path)"
        }
    }
}

public struct NonSteamLaunch: Sendable {
    public var paths: Paths
    public var game: NonSteamGame

    public init(game: NonSteamGame, paths: Paths = Paths()) {
        self.game = game
        self.paths = paths
    }

    public var runScript: URL { paths.steam.compatTools.appending(path: "wovengames-proton/run") }

    /// The run script's arguments and environment, as Steam would pass them.
    public func command(base: [String: String] = ProcessInfo.processInfo.environment) -> (arguments: [String], environment: [String: String]) {
        let exe = URL(filePath: game.exe)
        var env = base
        env["WOVEN_NO_STEAM"] = "1"
        env["STEAM_COMPAT_APP_ID"] = game.id
        env["STEAM_COMPAT_DATA_PATH"] = NonSteamGames(paths: paths).compatData(id: game.id).path(percentEncoded: false)
        env["STEAM_COMPAT_INSTALL_PATH"] = exe.deletingLastPathComponent().path(percentEncoded: false).trimmingSuffix("/")
        // the bridge staging copies Valve's DLLs from here, as for a Steam game
        env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = paths.steam.userData.path(percentEncoded: false)
        return (["waitforexitandrun", game.exe] + game.args, env)
    }

    /// Starts the game and returns without waiting for it.
    public func start() throws {
        let fm = FileManager.default
        let script = runScript.path(percentEncoded: false)
        guard fm.isExecutableFile(atPath: script) else { throw NonSteamLaunchError.noCompatTool }
        guard (try? String(contentsOf: runScript, encoding: .utf8))?.contains("WOVEN_NO_STEAM") == true else {
            throw NonSteamLaunchError.oldCompatTool
        }
        guard fm.fileExists(atPath: game.exe) else { throw NonSteamLaunchError.missingExe(game.exe) }
        let compat = NonSteamGames(paths: paths).compatData(id: game.id)
        try fm.createDirectory(at: compat, withIntermediateDirectories: true)

        let (arguments, environment) = command()
        let process = Process()
        process.executableURL = runScript
        process.arguments = arguments
        process.environment = environment
        // Steam starts the script in the game's folder
        process.currentDirectoryURL = URL(filePath: game.exe).deletingLastPathComponent()
        // the script writes its own log (wovengames-run.log in the compatdata folder)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
