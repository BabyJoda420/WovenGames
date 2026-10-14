// State and actions behind the app's windows

import AppKit
import Foundation
import Observation
import WovenCore

@MainActor
@Observable
final class AppModel {
    var checks: [Check] = []
    var steam: SteamStatus?
    var games: [InstalledGame] = []
    /// bumped on every refresh and when a game quits, so views can re-read things (launch logs) that change while games stay the same
    var generation = 0
    var runner: Runner?
    /// a built engine waiting to be installed (Library/Developer/WovenGames/engine)
    var engineBuilt = false
    /// Steam.app carries an older hook than the installed one
    var hookOutdated = false
    /// Steam build support, with Valve's newest builds (loaded after the rest)
    var builds: SteamBuildReport?
    /// App Management permission for this app (nil until checked; checking can make macOS
    /// show its "prevented from modifying apps" notice, so it only runs in setup and patching)
    var access: AppManagementAccess?
    var showSetup = false
    var busy: String?
    /// lines from the last action, shown under the status checks
    var activity: [String] = []
    var error: String?

    let paths = Paths()

    /// CFBundleShortVersionString; "0.0.0" when running outside an app bundle (swift run)
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    // MARK: games (AppModel+Games.swift)

    /// app IDs of games running now: their launcher app is open, or their run script is alive
    var runningGames: Set<String> = []
    /// a game a notification asked to show; the Games page selects it, then sets this back to nil
    var requestedGame: String?
    /// launch findings per app ID, worst first; nil for a game not diagnosed yet (see findings(for:))
    var launchFindings: [String: [LaunchFinding]] = [:]
    @ObservationIgnored var findingsInFlight: Set<String> = []
    @ObservationIgnored var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored var notificationRouter: NotificationRouter?
    /// set by the app scene to its openWindow(id: "main"), so a notification can reopen a closed window
    @ObservationIgnored var openMainWindow: (@MainActor () -> Void)?

    // MARK: updates (AppModel+Updates.swift)

    /// a newer WovenGames release for this Mac (betas only with "includeBetas")
    var availableUpdate: GitHubRelease?
    var checkingForUpdates = false
    /// when the last update check succeeded
    var lastUpdateCheck: Date?
    @ObservationIgnored var updateLoop: Task<Void, Never>?
    /// a Steam update has lifted the pin; quitting the app now must pin Steam again
    var steamUpdateInProgress = false
    @ObservationIgnored var recommendationSync: Task<Void, Never>?

    // MARK: settings (AppModel+Settings.swift)

    /// what global.env holds; read at refresh, written through fpsOverlay
    var fpsOverlayValue = false
    @ObservationIgnored var fpsOverlayWrite: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: Setting.defaults)
        appLog("WovenGames \(appVersion) started")
        observeLaunchers()
        setUpNotifications()
        startUpdateLoop()
    }

    var isReady: Bool {
        runner != nil && steam?.injection == .wovenGames
    }

    func refresh() async {
        let paths = paths
        syncRecommendationsQuietly()
        // a pending write would otherwise be read back as the old value
        await fpsOverlayWrite?.value
        let snapshot = await Task.detached {
            (WovenCore.Doctor.run(paths: paths),
             SteamStatus(paths: paths.steam),
             SteamLibrary(paths: paths).windowsGames() + NonSteamGames(paths: paths).installedGames(),
             try? RunnerStore(paths: paths).current(),
             FileManager.default.fileExists(atPath: EngineBuild.locate(paths: paths).root
                .appending(path: "dist/runners/selfbuilt-cx26.3-r1/runner.json").path(percentEncoded: false)),
             !SteamPatcher(paths: paths).deployedHookIsCurrent,
             GameSessions(paths: paths).running(),
             GlobalSettings(paths: paths).fpsOverlay)
        }.value
        let sessions: [String]
        (checks, steam, games, runner, engineBuilt, hookOutdated, sessions, fpsOverlayValue) = snapshot
        runningGames = launcherGames().union(sessions)
        generation += 1
        rediagnoseAll()
        builds = SteamBuilds.localReport(paths: paths)
        builds = await SteamBuilds.fullReport(paths: paths)
    }

    // MARK: actions (each runs off the main thread, then refreshes)

    /// A local engine build wins (for developers); otherwise the newest GitHub release.
    func installEngine() async {
        if engineBuilt {
            await perform("Installing the engine") { log in try Setup().run(log: log) }
        } else {
            await performAsync("Downloading and installing WovenGames") { log in
                let url = try await ReleaseInstaller.latestReleaseAsset()
                log("release: \(url.lastPathComponent)")
                try await ReleaseInstaller().install(archive: url, log: log)
            }
        }
    }

    func patchSteam() async {
        await perform("Patching Steam") { log in
            try SteamPatcher().patch(pinning: true, log: log)
            log("Steam no longer updates at launch")
        }
        await checkAccess()
        // macOS refused: walk the user through allowing it
        if access == .denied { showSetup = true }
    }

    func checkAccess() async {
        let app = paths.steamApp
        access = await Task.detached { AppManagement.probe(steamApp: app) }.value
        appLog("App Management for Steam.app: \(access.map { "\($0)" } ?? "unknown")")
    }

    /// ~/Library/Application Support/WovenGames/logs/app.log, for support questions.
    /// Callable from any thread (background syncs log too); the lock keeps lines whole.
    nonisolated func appLog(_ line: String) {
        Self.logLock.lock()
        defer { Self.logLock.unlock() }
        let url = paths.logs.appending(path: "app.log")
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private nonisolated static let logLock = NSLock()

    func openAppManagementSettings() {
        if !NSWorkspace.shared.open(AppManagement.settingsURL) {
            NSWorkspace.shared.open(AppManagement.legacySettingsURL)
        }
    }

    /// macOS applies a changed App Management switch to an app when it starts again.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func restoreSteam() async {
        await perform("Restoring Steam") { log in try SteamPatcher().unpatch(log: log) }
    }

    func pin(_ on: Bool) async {
        await perform(on ? "Pinning Steam" : "Unpinning Steam") { log in
            if on { try SteamPatcher().pin(); log("Steam no longer updates at launch") }
            else { try SteamPatcher().unpin(); log("Steam updates at its next launch; the hook may need an update afterwards") }
        }
    }

    func resetPrefix(of game: InstalledGame) async {
        await perform("Resetting \(game.name)") { log in
            guard FileManager.default.fileExists(atPath: game.prefix.path(percentEncoded: false)) else {
                log("no prefix yet"); return
            }
            try FileManager.default.trashItem(at: game.prefix, resultingItemURL: nil)
            log("moved the prefix to the Trash; it is rebuilt at the next launch (saves synced to Steam Cloud come back)")
        }
    }

    func perform(_ title: String, _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) throws -> Void) async {
        await performAsync(title) { log in try work(log) }
    }

    /// Runs `work` off the main thread with `busy` set, collecting its log lines in `activity`
    /// and a thrown error in `error`, then refreshes. Used by the extensions too.
    func performAsync(_ title: String, _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void) async {
        busy = title
        activity = []
        error = nil
        let stream = AsyncStream<String> { continuation in
            Task.detached {
                do {
                    try await work { continuation.yield($0) }
                } catch {
                    continuation.yield("error: \(error)")
                }
                continuation.finish()
            }
        }
        for await line in stream {
            if line.hasPrefix("error: ") { error = String(line.dropFirst(7)) } else { activity.append(line) }
        }
        busy = nil
        appLog("\(title): \(error.map { "failed: \($0)" } ?? "done")")
        await refresh()
    }

    // MARK: Finder and Console

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openSteam() {
        NSWorkspace.shared.open(URL(filePath: "/Applications/Steam.app"))
    }
}
