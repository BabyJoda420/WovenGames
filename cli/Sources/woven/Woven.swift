import ArgumentParser
import Foundation
import WovenCore

@main
struct Woven: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "WovenGames: play Windows games on Apple Silicon.",
        version: "0.1.0",
        subcommands: [Doctor.self, RunnerCommand.self, PrefixCommand.self, BackendCommand.self, Run.self, SteamCommand.self]
    )
}

// MARK: - doctor

extension Woven {
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check whether this Mac is ready to play.")

        func run() throws {
            let checks = WovenCore.Doctor.run()
            let width = checks.map(\.title.count).max() ?? 0
            for check in checks {
                let mark = switch check.level {
                case .ok: "✓"
                case .info: "·"
                case .warn: "!"
                case .fail: "✗"
                }
                print("\(mark) \(check.title.padding(toLength: width, withPad: " ", startingAt: 0))  \(check.detail)")
            }
            if checks.contains(where: { $0.level == .fail }) { throw ExitCode(1) }
        }
    }
}

// MARK: - runner

extension Woven {
    struct RunnerCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "runner",
            abstract: "Manage Wine runners.",
            subcommands: [List.self, Install.self, Use.self]
        )

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List installed runners.")
            func run() throws {
                let store = RunnerStore()
                let current = try? store.current().id
                let runners = store.list()
                if runners.isEmpty { print("no runners installed"); return }
                for r in runners {
                    let backends = Backend.allCases.filter { r.has($0) }.map(\.rawValue).joined(separator: ", ")
                    print("\(r.id == current ? "*" : " ") \(r.id)  \(r.manifest.wine ?? "?")  [\(backends)]")
                }
            }
        }

        struct Install: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Install a built runner and select it.")

            @Argument(help: "Runner directory (default: the newest engine build).")
            var path: String?

            @Flag(help: "Symlink instead of copying (for runners you are still rebuilding).")
            var link = false

            func run() throws {
                let source: URL
                if let path {
                    source = URL(filePath: path, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                } else {
                    let dist = Paths().engineDist
                    let built = ((try? FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                        .filter { FileManager.default.fileExists(atPath: $0.appending(path: "runner.json").path(percentEncoded: false)) }
                    guard let newest = built.max(by: { modified($0) < modified($1) }) else {
                        throw ValidationError("no built runner in \(dist.path(percentEncoded: false)); run engine/scripts/build-all.sh first")
                    }
                    source = newest
                }
                let runner = try RunnerStore().install(from: source, link: link)
                print("installed and selected \(runner.id)")
            }

            func modified(_ url: URL) -> Date {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            }
        }

        struct Use: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Select the runner games use.")
            @Argument var id: String
            func run() throws {
                try RunnerStore().use(id)
                print("selected \(id)")
            }
        }
    }
}

// MARK: - prefix

extension Woven {
    struct PrefixCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prefix",
            abstract: "Manage Wine prefixes (one per game).",
            subcommands: [List.self, Create.self, Delete.self]
        )

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List prefixes.")
            func run() {
                let names = Prefixes().list()
                print(names.isEmpty ? "no prefixes" : names.joined(separator: "\n"))
            }
        }

        struct Create: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Create or update a prefix (wineboot -u).")
            @Argument var name: String
            func run() throws {
                let status = try Prefixes().create(name, runner: try RunnerStore().current())
                guard status == 0 else { throw ExitCode(status) }
                print("prefix \(name) ready")
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Move a prefix to the Trash.")
            @Argument var name: String
            func run() throws {
                try Prefixes().delete(name)
                print("moved \(name) to the Trash")
            }
        }
    }
}

// MARK: - backend

extension Woven {
    struct BackendCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "backend",
            abstract: "Graphics backend selection.",
            subcommands: [Detect.self]
        )

        struct Detect: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show which backend a game would get, and why.")

            @Argument(help: "The game's .exe.")
            var exe: String

            @Option(help: "The game's install folder (default: the .exe's folder).")
            var gameDir: String?

            func run() {
                let target = URL(filePath: exe).standardizedFileURL
                let dir = gameDir.map { URL(filePath: $0).standardizedFileURL } ?? target.deletingLastPathComponent()
                let detection = BackendDetector.detect(launchTarget: target, installDir: dir)
                detection.notes.forEach { print("  \($0)") }
                print("api: \(detection.api.rawValue) -> backend: \(detection.backend.rawValue)")
            }
        }
    }
}

// MARK: - run

extension Woven {
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a Windows program.")

        enum BackendChoice: String, ExpressibleByArgument, CaseIterable {
            case auto, d3dmetal, dxmt, wined3d
        }

        @Option(help: "Prefix name.")
        var prefix = "default"

        @Option(help: "Graphics backend.")
        var backend: BackendChoice = .auto

        @Option(help: "The game's install folder for backend detection (default: the .exe's folder).")
        var gameDir: String?

        @Flag(inversion: .prefixedNo, help: "msync (faster synchronisation).")
        var msync = true

        @Flag(help: "Show Apple's Metal performance HUD.")
        var hud = false

        @Option(help: "WINEDEBUG channels, e.g. +d3d or -all.")
        var debug: String?

        @Flag(help: "Write Wine's output to ~/Library/Application Support/WovenGames/logs instead of the terminal.")
        var log = false

        @Argument(help: "The .exe (or a Wine program such as winecfg).")
        var program: String

        @Argument(parsing: .captureForPassthrough, help: "Arguments for the program.")
        var arguments: [String] = []

        func run() throws {
            let runner = try RunnerStore().current()
            let prefixURL = try Prefixes().url(prefix)

            let target = URL(filePath: program).standardizedFileURL
            let isFile = FileManager.default.fileExists(atPath: target.path(percentEncoded: false))
            let chosen: Backend
            if let explicit = Backend(rawValue: backend.rawValue) {
                chosen = explicit
            } else if isFile {
                let dir = gameDir.map { URL(filePath: $0).standardizedFileURL } ?? target.deletingLastPathComponent()
                let detection = BackendDetector.detect(launchTarget: target, installDir: dir)
                chosen = detection.backend
                print("graphics: \(chosen.rawValue) (auto, \(detection.api.rawValue))")
            } else {
                chosen = .wined3d
            }
            guard runner.has(chosen) else { throw ValidationError("runner \(runner.id) has no \(chosen.rawValue)") }

            var launch = WineLaunch(runner: runner, prefix: prefixURL, backend: chosen)
            launch.msync = msync
            launch.hud = hud
            launch.debug = debug

            var logURL: URL?
            if log {
                let logs = Paths().logs
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                logURL = logs.appending(path: "\(target.deletingPathExtension().lastPathComponent)-\(stamp).log")
                print("log: \(logURL!.path(percentEncoded: false))")
            }
            let status = try launch.run([isFile ? target.path(percentEncoded: false) : program] + arguments, log: logURL)
            if status != 0 { throw ExitCode(status) }
        }
    }
}

// MARK: - steam

extension Woven {
    struct SteamCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "steam",
            abstract: "macOS Steam integration.",
            subcommands: [Status.self]
        )

        struct Status: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show Steam's build, hook and update pin.")
            func run() {
                let s = SteamStatus(paths: Paths().steam)
                print("installed: \(s.installed)")
                print("running:   \(s.running)")
                print("build:     \(s.clientBuild ?? "unknown")")
                print("pending:   \(s.pendingBuild ?? "none")")
                print("hook:      \(s.injection)")
                print("pin:       \(s.pin)")
            }
        }
    }
}
