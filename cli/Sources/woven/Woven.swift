import ArgumentParser
import Foundation
import WovenCore

@main
struct Woven: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "WovenGames: play Windows games on Apple Silicon.",
        version: "0.2.0-beta.1",
        subcommands: [Doctor.self, Install.self, Setup.self, RunnerCommand.self, PrefixCommand.self, BackendCommand.self, Run.self, SteamCommand.self, GamesCommand.self, CompatCommand.self, Update.self, Report.self]
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

// MARK: - setup

extension Woven {
    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the engine build (runner, Steam bridge, hook, helpers) into Application Support."
        )
        @Option(help: "Runner id in the engine build.") var runner = "selfbuilt-cx26.3-r1"
        func run() throws {
            try WovenCore.Setup(payload: EngineBuild.locate().payload(runnerID: runner)).run { print($0) }
            print("done; next: woven steam patch")
        }
    }
}

// MARK: - install

extension Woven {
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install a WovenGames release: the engine, plus D3DMetal and Valve's Steam DLLs fetched on this Mac.",
            discussion: "Pass a wovengames-engine-*.tar.xz file or URL, or --latest for the newest GitHub release."
        )

        @Argument(help: "Release archive path or URL.") var archive: String?
        @Flag(help: "Install the newest release from GitHub.") var latest = false

        func run() async throws {
            let url: URL
            if latest {
                url = try await ReleaseInstaller.latestReleaseAsset()
                print("latest release: \(url.absoluteString)")
            } else if let archive, let remote = URL(string: archive), remote.scheme == "https" {
                url = remote
            } else if let archive {
                url = URL(filePath: archive, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL
            } else {
                throw ValidationError("pass a release archive, a URL, or --latest")
            }
            try await ReleaseInstaller().install(archive: url) { print($0) }
            print("done; next: woven steam patch")
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
                    source = URL(filePath: path, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL
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
            subcommands: [Status.self, Builds.self, Update.self, Patch.self, Unpatch.self, Pin.self, Unpin.self, Log.self]
        )

        struct Builds: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show whether the hook supports the installed, pending and newest Steam builds."
            )
            @Flag(help: "Only what is on this Mac (no Valve or GitHub lookups).") var offline = false

            func run() async throws {
                let r = offline ? SteamBuilds.localReport() : await SteamBuilds.fullReport()
                func row(_ title: String, _ build: String?) {
                    guard let build else { return }
                    print("\(title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(build)  \(r.verdict(for: build).label)")
                }
                row("installed", r.installed)
                row("pending update", r.pending)
                row("newest public", r.latestPublic)
                row("newest beta", r.latestBeta)
                if let s = r.session {
                    let f = { (c: HookSession.Count?) in c.map { "\($0.done)/\($0.total)" } ?? "-" }
                    print("last Steam start: signatures \(f(s.signatures)), hooks \(f(s.hooks)), Steam UI signatures \(f(s.uiSignatures)), Steam UI hooks \(f(s.uiHooks))\(r.sessionOnInstalled ? "" : " (on an earlier build)")")
                }
                if let newest = r.latestPublic, newest != r.installed, r.verdict(for: newest).isSafe {
                    print("\nSteam \(newest) is checked: `woven steam unpin`, start Steam to update, then `woven steam pin`.")
                }
            }
        }

        struct Patch: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Inject the WovenGames hook into /Applications/Steam.app (quits Steam).",
                discussion: "Needs App Management permission for your terminal. Takes over a NotProton install."
            )
            func run() throws {
                try SteamPatcher().patch { print($0) }
                try SteamPatcher().pin()
                print("Steam no longer updates at launch (`woven steam unpin` to allow it)")
            }
        }

        struct Unpatch: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Remove the hook and restore Steam's Info.plist (quits Steam).")
            func run() throws { try SteamPatcher().unpatch { print($0) } }
        }

        struct Pin: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Stop Steam from updating at launch.")
            func run() throws {
                try SteamPatcher().pin()
                print("pinned")
            }
        }

        struct Unpin: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Let Steam update again.")
            func run() throws {
                try SteamPatcher().unpin()
                print("unpinned; Steam updates at its next launch")
            }
        }

        struct Log: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show the end of the hook's log.")
            @Option(name: .shortAndLong, help: "Lines to show.") var lines = 40
            func run() throws {
                let url = Paths().hookLog
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    print("no log yet at \(url.path(percentEncoded: false)) (start Steam once after `woven steam patch`)")
                    return
                }
                print(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n"))
            }
        }

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
