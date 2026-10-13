import ArgumentParser
import Foundation
import WovenCore

/// Prints an error the way the CLI reports it, then exits 1.
func fail(_ error: Error) -> ExitCode {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    return ExitCode(1)
}

/// A plain message for `fail`, for errors that are not about the command line's syntax.
struct Message: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

// MARK: - steam update

extension Woven.SteamCommand {
    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Update Steam to Valve's newest build, if WovenGames has checked it (restarts Steam).",
            discussion: "Lifts the update pin, restarts Steam so it installs the build, waits for the hook to load, and pins again."
        )
        @Flag(name: .shortAndLong, help: "Do not ask before quitting Steam.") var yes = false

        func run() async throws {
            let report = await SteamBuilds.fullReport()
            let updater = SteamUpdater()
            let target: String
            do { target = try updater.preflight(report) } catch { throw fail(error) }
            print("Steam \(report.installed ?? "?") → \(target) (checked)")
            print("Steam will be quit, restarted to install the update, and pinned to the new build again.")
            if !yes {
                print("Continue? [y/N] ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                guard answer == "y" || answer == "yes" else { print("cancelled"); return }
            }
            do { try await updater.update(report) { print($0) } } catch { throw fail(error) }
        }
    }
}

// MARK: - compat

extension Woven {
    struct CompatCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compat",
            abstract: "Game recommendations from GitHub.",
            subcommands: [Sync.self]
        )

        struct Sync: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Fetch the newest game recommendations now.")
            func run() async throws {
                let result: CompatSync.Result
                do { result = try await CompatSync().run(force: true) { print($0) } } catch { throw fail(error) }
                if result.updated.isEmpty && result.removed.isEmpty { print("up to date") }
            }
        }
    }
}

// MARK: - games

extension Woven {
    struct GamesCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "games",
            abstract: "Installed Windows games in Steam.",
            discussion: "With no subcommand, lists the games.",
            subcommands: [List.self, Diagnose.self, Quit.self]
        )

        // runs `list` itself: a defaultSubcommand would also take over `woven games --help`
        func run() async throws { try List().run() }

        static func game(_ appID: String) throws -> InstalledGame {
            let games = SteamLibrary().windowsGames()
            guard let game = games.first(where: { $0.appID == appID }) else {
                throw fail(Message("no installed Windows game with app id \(appID); `woven games` lists them (the id is also in the game's Steam store URL)"))
            }
            return game
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List installed Windows games and their last run.")
            func run() {
                let games = SteamLibrary().windowsGames()
                if games.isEmpty { print("no Windows games installed in Steam"); return }
                let running = Set(GameSessions().running())
                let idWidth = games.map(\.appID.count).max() ?? 0
                for game in games {
                    var parts = [game.appID.padding(toLength: idWidth, withPad: " ", startingAt: 0), game.name]
                    if running.contains(game.appID) { parts.append("running") }
                    if let run = SteamLibrary.lastRun(of: game) {
                        var last = "last run: \(run.backend ?? "?")"
                        if let stage = run.abortedStage { last += ", aborted during \(stage)" }
                        else if run.terminated { last += ", stopped" }
                        else if let status = run.exitStatus { last += ", exit \(status)" }
                        if let seconds = run.seconds { last += " after \(seconds)s" }
                        parts.append(last)
                    }
                    print(parts.joined(separator: "  "))
                }
            }
        }

        struct Diagnose: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Explain why a game did not start, and how to fix it.")
            @Argument(help: "The game's Steam app id (see `woven games`).") var appID: String

            func run() throws {
                let game = try GamesCommand.game(appID)
                let findings = LaunchDiagnosis.findings(
                    run: SteamLibrary.lastRun(of: game),
                    launchOptions: SteamLaunchOptions.read(appID: appID),
                    runner: try? RunnerStore().current(),
                    settings: GameSettings.load(appID: appID),
                    detected: BackendDetector.detect(launchTarget: nil, installDir: game.installDir).backend
                )
                if findings.isEmpty { print("no problems found"); return }
                for (i, finding) in findings.enumerated() {
                    if i > 0 { print("") }
                    let mark = switch finding.severity {
                    case .error: "✗"
                    case .warning: "!"
                    case .info: "·"
                    }
                    print("\(mark)  \(finding.title)")
                    print("   \(finding.detail)")
                    if let fix = finding.fix { print("   fix: \(describe(fix, game: game))") }
                }
            }

            func describe(_ fix: LaunchFinding.Fix, game: InstalledGame) -> String {
                switch fix {
                case .resetPrefix: "reset the game's prefix in the WovenGames app (moves \(game.prefix.path(percentEncoded: false)) to the Trash)"
                case .installEngine: "reinstall the engine: woven install --latest"
                case .launchOptions(let options): "set the launch options in Steam to:\n   \(options)"
                case .switchBackend(let choice): "switch the graphics backend to \(choice.label) in the WovenGames app"
                case .openLaunchLog: "read the launch log: \(game.runLog.path(percentEncoded: false))"
                }
            }
        }

        struct Quit: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Force quit a running game.")
            @Argument(help: "The game's Steam app id (see `woven games`).") var appID: String

            func run() async throws {
                let game = try GamesCommand.game(appID)
                guard GameSessions().running().contains(appID) else {
                    throw fail(Message("\(game.name) is not running"))
                }
                await GameSessions().forceQuit(appID: appID, prefix: game.prefix) { print($0) }
            }
        }
    }
}

// MARK: - update

extension Woven {
    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check for a newer WovenGames release and install its engine."
        )
        @Flag(help: "Only check; install nothing.") var check = false
        @Flag(help: "Include beta releases.") var beta = false

        func run() async throws {
            let current = Version(Woven.configuration.version)!
            let release: GitHubRelease?
            do { release = try await UpdateCheck(current: current, includeBetas: beta).newer() } catch { throw fail(error) }
            guard let release, let version = release.version else {
                print("WovenGames is up to date (\(current))")
                return
            }
            print("WovenGames \(version) is available: \(release.html_url)")
            if check { return }
            guard let archive = release.engineArchive else { throw fail(Message("release \(version) has no engine archive")) }
            do { try await ReleaseInstaller().install(archive: archive) { print($0) } } catch { throw fail(error) }
            print("engine \(version) installed")
            print("Update the app itself from the WovenGames app, or download the zip from \(release.html_url)")
        }
    }
}

// MARK: - report

extension Woven {
    struct Report: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collect logs and system details (with personal paths removed) for a GitHub issue."
        )
        @Option(name: .shortAndLong, help: "What went wrong, in your own words.") var message = ""
        @Option(name: .shortAndLong, help: "Folder to write the report to.") var output = "~/Desktop"

        func run() throws {
            let dir = URL(filePath: NSString(string: output).expandingTildeInPath,
                          relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL
            let out: ProblemReport.Output
            do { out = try ProblemReport(appVersion: Woven.configuration.version, description: message).write(to: dir) } catch { throw fail(error) }
            print("folder: \(out.folder.path(percentEncoded: false))")
            print("zip:    \(out.zip.path(percentEncoded: false))")
            print("Review the folder, then attach the zip to a new issue at https://github.com/BabyJoda420/WovenGames/issues/new")
        }
    }
}
