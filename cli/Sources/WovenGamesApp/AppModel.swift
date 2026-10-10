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
    var runner: Runner?
    /// a built engine waiting to be installed (Library/Caches/WovenGames/engine)
    var engineBuilt = false
    /// Steam.app carries an older hook than the installed one
    var hookOutdated = false
    /// Steam build support, with Valve's newest builds (loaded after the rest)
    var builds: SteamBuildReport?
    var busy: String?
    /// lines from the last action, shown under the status checks
    var activity: [String] = []
    var error: String?

    let paths = Paths()

    var isReady: Bool {
        runner != nil && steam?.injection == .wovenGames
    }

    func refresh() async {
        let paths = paths
        let snapshot = await Task.detached {
            (WovenCore.Doctor.run(paths: paths),
             SteamStatus(paths: paths.steam),
             SteamLibrary(paths: paths).windowsGames(),
             try? RunnerStore(paths: paths).current(),
             FileManager.default.fileExists(atPath: EngineBuild.locate(paths: paths).root
                .appending(path: "dist/runners/selfbuilt-cx26.3-r1/runner.json").path(percentEncoded: false)),
             !SteamPatcher(paths: paths).deployedHookIsCurrent)
        }.value
        (checks, steam, games, runner, engineBuilt, hookOutdated) = snapshot
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
            try SteamPatcher().patch(log: log)
            try SteamPatcher().pin()
            log("Steam no longer updates at launch")
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

    private func perform(_ title: String, _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) throws -> Void) async {
        await performAsync(title) { log in try work(log) }
    }

    private func performAsync(_ title: String, _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void) async {
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
