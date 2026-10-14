// Games running right now, why a launch failed, and starting or stopping a game

import AppKit
import Foundation
import WovenCore

extension AppModel {
    /// Each launch opens a small app named after the game with this bundle ID plus the app ID,
    /// so its launch and quit say when a game starts and stops.
    nonisolated static let launcherPrefix = "com.wovengames.launcher."

    nonisolated static func launcherAppID(_ bundleID: String?) -> String? {
        guard let bundleID, bundleID.hasPrefix(launcherPrefix) else { return nil }
        let id = String(bundleID.dropFirst(launcherPrefix.count))
        return id.isEmpty ? nil : id
    }

    nonisolated static func launcherAppID(in note: Notification) -> String? {
        launcherAppID((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier)
    }

    /// Games whose launcher app is open now (in memory, no disk access).
    func launcherGames() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { Self.launcherAppID($0.bundleIdentifier) })
    }

    func observeLaunchers() {
        runningGames = launcherGames()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.launcherAppID(in: note) else { return }
                MainActor.assumeIsolated { _ = self?.runningGames.insert(id) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.launcherAppID(in: note) else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.gameEnded(id) }
                }
            },
        ]
    }

    /// A game's launcher quit: read how the run ended and tell the player when it went wrong.
    func gameEnded(_ appID: String) async {
        runningGames.remove(appID)
        guard let game = games.first(where: { $0.appID == appID }) else { return }
        let paths = paths
        await Task.detached { await Self.waitForSessionEnd(of: game, paths: paths) }.value
        let found = await diagnose(game)
        generation += 1
        appLog("\(game.name) (\(appID)) quit: \(found.first.map { "\($0.severity): \($0.title)" } ?? "no problems found")")
        // only problems with the launch that just ended; setup findings stay on the Games page
        guard UserDefaults.standard.bool(forKey: Setting.notifyLaunchProblems),
              let worst = LaunchDiagnosis.notifiable(found) else { return }
        postNotification(id: "launch-\(appID)",
                         title: worst.severity == .error ? "\(game.name) didn't start" : "\(game.name) closed right after starting",
                         body: worst.title,
                         appID: appID)
    }

    /// Waits until the run script has finished the session that just ended: it logs
    /// "=== game exited" only after the game's prefix has been idle for 10 seconds or more,
    /// then kills the prefix and removes run.pid. The launcher quits while this run is the
    /// last one in the log (the script logs its header before it creates the launcher).
    nonisolated static func waitForSessionEnd(of game: InstalledGame, paths: Paths, timeout: Int = 90) async {
        let sessions = GameSessions(paths: paths)
        for _ in 0..<timeout {
            if let run = SteamLibrary.lastRun(of: game), run.ended { return }
            // the script is gone (run.pid removed, or killed outright): the log will not change
            if sessions.runScript(appID: game.appID) == nil { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: launch findings

    /// What went wrong with the game's last launch, worst first. Answers from the cache; a game
    /// not diagnosed yet returns [] and is diagnosed in the background (launchFindings[appID]
    /// stays nil until then, so a view can tell "nothing found" from "not checked yet").
    func findings(for game: InstalledGame) -> [LaunchFinding] {
        if let cached = launchFindings[game.appID] { return cached }
        if !findingsInFlight.contains(game.appID) {
            findingsInFlight.insert(game.appID)
            Task { await diagnose(game) }
        }
        return []
    }

    /// Diagnoses a game now (off the main thread) and caches the result.
    @discardableResult
    func diagnose(_ game: InstalledGame) async -> [LaunchFinding] {
        findingsInFlight.insert(game.appID)
        let paths = paths
        let found = await Task.detached { Self.computeFindings(for: game, paths: paths) }.value
        findingsInFlight.remove(game.appID)
        launchFindings[game.appID] = found
        return found
    }

    /// After a refresh: games already diagnosed are diagnosed again (old answers stay visible
    /// meanwhile), and games no longer installed are dropped.
    func rediagnoseAll() {
        let installed = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0) })
        for id in launchFindings.keys where installed[id] == nil { launchFindings[id] = nil }
        for id in launchFindings.keys { if let game = installed[id] { Task { await diagnose(game) } } }
    }

    nonisolated static func computeFindings(for game: InstalledGame, paths: Paths) -> [LaunchFinding] {
        let settings = GameSettings.load(appID: game.appID, paths: paths)
        // the detected backend only matters for Automatic; the scan reads the game's executables
        let detected = settings.backend == .auto
            ? BackendDetector.detect(launchTarget: nil, installDir: game.installDir).backend : nil
        let isUE = LaunchDiagnosis.isUnrealEngine(installDir: game.installDir)
        return LaunchDiagnosis.findings(run: SteamLibrary.lastRun(of: game),
                                        launchOptions: SteamLaunchOptions.read(appID: game.appID, paths: paths),
                                        runner: RunnerStore(paths: paths).runner(for: settings),
                                        settings: settings,
                                        detected: detected,
                                        isUnreal: isUE)
    }

    // MARK: play and stop

    /// Starts the game through Steam, which runs it with WovenGames.
    func play(_ game: InstalledGame) {
        guard let url = URL(string: "steam://rungameid/\(game.appID)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Stops a game that hangs, the way Steam's Stop does, harder if that does not work.
    func forceQuit(_ game: InstalledGame) async {
        let paths = paths
        await performAsync("Quitting \(game.name)") { log in
            await GameSessions(paths: paths).forceQuit(appID: game.appID, prefix: game.prefix, log: log)
        }
    }
}
