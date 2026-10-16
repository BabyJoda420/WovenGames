// New WovenGames releases, newer Steam builds and the game recommendations from GitHub

import AppKit
import Foundation
import WovenCore

enum AppUpdateError: Error, CustomStringConvertible {
    case gameRunning

    var description: String {
        switch self {
        case .gameRunning: "a game is running; quit it first (the update replaces the engine it runs on)"
        }
    }
}

extension AppModel {
    var appVersionValue: Version { Version(appVersion) ?? Version("0.0.0")! }

    // MARK: app updates

    /// Checks at launch, then every 12 hours while WovenGames runs, unless "checkForUpdates" is off.
    func startUpdateLoop() {
        updateLoop = Task { [weak self] in
            while !Task.isCancelled {
                if UserDefaults.standard.bool(forKey: Setting.checkForUpdates) {
                    await self?.checkForUpdates(manual: false)
                }
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }

    /// Sets availableUpdate. A manual check (the user is looking) reports failures in `error`;
    /// a background one only logs them and posts a notification once per new version.
    func checkForUpdates(manual: Bool) async {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        // the engine can be older than the app (the app was updated from the zip): then the
        // release matching the app is offered for its engine
        let check = UpdateCheck(current: UpdateCheck.baseline(app: appVersionValue, paths: paths), includeBetas: UserDefaults.standard.bool(forKey: Setting.includeBetas))
        do {
            let release = try await Task.detached { try await check.newer() }.value
            availableUpdate = release
            lastUpdateCheck = Date()
            appLog("update check: \(release.map { "\($0.tag_name) available" } ?? "up to date (\(appVersion))")")
            guard let release, UserDefaults.standard.string(forKey: Setting.notifiedUpdateVersion) != release.tag_name else { return }
            UserDefaults.standard.set(release.tag_name, forKey: Setting.notifiedUpdateVersion)
            if !manual {
                postNotification(id: "update", title: "WovenGames \(release.version?.description ?? release.tag_name) is available",
                                 body: "Open WovenGames to install it.")
            }
        } catch {
            appLog("update check failed: \(error)")
            if manual { self.error = "Could not check for updates: \(error)" }
        }
    }

    /// Installs availableUpdate: downloads the app, installs the engine, then the new app
    /// replaces this one and restarts. Where this copy cannot be replaced (a read-only folder,
    /// a development build in cli/.build), the new app is shown in Finder instead.
    func installUpdate() async {
        guard let release = availableUpdate else { return }
        let version = release.version?.description ?? release.tag_name
        let paths = paths
        let running = Bundle.main.bundleURL
        let onlyEngine = release.onlyEngine(forApp: appVersionValue)
        let devBuild = running.pathExtension != "app" || running.path(percentEncoded: false).contains("/.build/")
        await performAsync("Installing WovenGames \(version)") { [self] log in
            // the engine is replaced under a running game otherwise
            guard !RunnerStore(paths: paths).inUse() else { throw AppUpdateError.gameRunning }
            // the app is downloaded and checked first: if that fails, the engine stays the one
            // this app was made with
            let newApp = release.appArchive == nil || onlyEngine ? nil
                : try await AppUpdate.download(release, staging: paths.support.appending(path: "updates/\(version)"), log: log)
            if let engine = release.engineArchive {
                try await ReleaseInstaller(paths: paths).install(archive: engine, log: log)
            }
            guard let newApp else {
                log("this release only updates the engine")
                return
            }
            let folder = running.deletingLastPathComponent()
            if devBuild {
                log("this is a development build, so it stays; the new app is shown in Finder")
                await reveal(newApp)
                return
            }
            guard FileManager.default.isWritableFile(atPath: folder.path(percentEncoded: false)) else {
                log("WovenGames cannot replace itself in \(folder.path(percentEncoded: false)); drag the new app shown in Finder there")
                await reveal(newApp)
                return
            }
            try Self.replaceApp(at: running, with: newApp, log: log)
            log("restarting into WovenGames \(version)")
            await relaunch()
        }
        // an engine-only update does not relaunch: clear the banner if the engine is current now
        if onlyEngine { await checkForUpdates(manual: false) }
    }

    /// Moves `old` to the Trash and `new` into its place; puts `old` back if the move fails.
    nonisolated static func replaceApp(at old: URL, with new: URL, log: (String) -> Void) throws {
        let fm = FileManager.default
        var trashed: NSURL?
        try fm.trashItem(at: old, resultingItemURL: &trashed)
        do {
            try fm.moveItem(at: new, to: old)
        } catch {
            if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: old) }
            throw error
        }
        log("the previous version is in the Trash")
    }

    // MARK: Steam

    /// Valve's newest public build is checked with the hook, and Steam carries the hook.
    var canUpdateSteam: Bool {
        guard let builds, let latest = builds.latestPublic else { return false }
        return latest != builds.installed && builds.verdict(for: latest).isSafe && steam?.injection == .wovenGames
    }

    /// Moves Steam to Valve's newest build when it is known to work, then pins it again.
    func updateSteam() async {
        let paths = paths
        steamUpdateInProgress = true
        defer { steamUpdateInProgress = false }
        await performAsync("Updating Steam") { log in
            // the report on screen can be hours old
            let report = await SteamBuilds.fullReport(paths: paths)
            try await SteamUpdater(paths: paths).update(report, log: log)
        }
    }

    // MARK: game recommendations

    /// At most every few hours (CompatSync's interval); failures only go to the log, since
    /// nothing the user asked for failed.
    func syncRecommendationsQuietly() {
        guard recommendationSync == nil else { return }
        let paths = paths
        // the model lives as long as the app, so holding it here is fine
        recommendationSync = Task.detached { [self] in
            do {
                let result = try await CompatSync(paths: paths).run(force: false)
                if !result.skipped {
                    appLog("recommendations: \(result.updated.count) updated, \(result.removed.count) removed")
                }
            } catch {
                appLog("recommendations sync failed: \(error)")
            }
            await MainActor.run { recommendationSync = nil }
        }
    }

    /// Fetches the recommendations now, whatever the interval.
    func syncRecommendations() async {
        let paths = paths
        await performAsync("Updating game recommendations") { log in
            let result = try await CompatSync(paths: paths).run(force: true, log: log)
            log(result.updated.isEmpty && result.removed.isEmpty
                ? "recommendations are up to date"
                : "\(result.updated.count) updated, \(result.removed.count) removed")
        }
    }
}
