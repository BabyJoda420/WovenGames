// Updating macOS Steam to a build the hook is known to work on, in one step.
//
// Steam stays pinned (steam.cfg) so an update cannot break the hook unannounced. When Valve's
// newest public build has been checked (steam-builds.json), this lifts the pin, restarts Steam
// so its bootstrapper installs that build, waits for the hook to load into the new client, and
// pins again. The pin comes back whatever happens.

import Foundation

public enum SteamUpdateError: Error, CustomStringConvertible, Equatable {
    case alreadyCurrent(String)
    case unknownLatest
    case notChecked(String, String)
    case gameRunning
    case steamMissing
    case notPatched
    case timedOut(installed: String?, target: String)
    case hookBroken(String)

    public var description: String {
        switch self {
        case .alreadyCurrent(let build): "Steam is already on \(build), Valve's newest build"
        case .unknownLatest: "could not reach Valve's update server to find the newest Steam build"
        case .notChecked(let build, let verdict): "Steam \(build) is \(verdict) with WovenGames; staying on the current build"
        case .gameRunning: "a game is running; quit it first (updating restarts Steam)"
        case .steamMissing: "Steam is not installed in /Applications"
        case .notPatched: "Steam does not have the WovenGames hook; patch Steam first"
        case .timedOut(let installed, let target):
            "Steam did not install \(target) in time (still on \(installed ?? "an unknown build")). Steam is pinned again; try once more, or update from Steam's own menu after turning off \"Keep Steam on this build\"."
        case .hookBroken(let why):
            "Steam updated, but the hook did not load fully (\(why)). Use Restore Steam if Steam misbehaves, and report it on GitHub."
        }
    }
}

public struct SteamUpdater: Sendable {
    public var paths: Paths
    /// false in tests: never quit or start the real Steam
    public var manageSteamProcess = true
    /// how long Steam may take to download and install the update
    public var installTimeout: TimeInterval = 15 * 60
    /// how long the restarted Steam may take to load the hook and its UI
    public var hookTimeout: TimeInterval = 4 * 60
    public var pollInterval: TimeInterval = 3

    public init(paths: Paths = Paths()) { self.paths = paths }

    /// Checks everything that can be checked before touching Steam; returns the target build.
    public func preflight(_ report: SteamBuildReport) throws -> String {
        let status = SteamStatus(paths: paths.steam)
        guard status.installed else { throw SteamUpdateError.steamMissing }
        guard status.injection == .wovenGames else { throw SteamUpdateError.notPatched }
        guard let target = report.latestPublic else { throw SteamUpdateError.unknownLatest }
        guard target != report.installed else { throw SteamUpdateError.alreadyCurrent(target) }
        let verdict = report.verdict(for: target)
        guard verdict.isSafe else { throw SteamUpdateError.notChecked(target, verdict.label) }
        if manageSteamProcess, RunnerStore(paths: paths).inUse() { throw SteamUpdateError.gameRunning }
        return target
    }

    public func update(_ report: SteamBuildReport, log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let target = try preflight(report)
        let patcher = { var p = SteamPatcher(paths: paths); p.manageSteamProcess = manageSteamProcess; return p }()
        log("updating Steam \(report.installed ?? "?") → \(target)")
        try patcher.quitSteam(log: log)
        do {
            // inside: an unpin that fails halfway has already lifted one of the pins
            try patcher.unpin()
            log("Steam may update at launch now")
            try await installAndVerify(target: target, log: log)
        } catch {
            try? patcher.pin()
            log("Steam is pinned to its build again")
            throw error
        }
        try patcher.pin()
        log("Steam \(target) works with WovenGames; pinned to it again")
    }

    func installAndVerify(target: String, log: @escaping @Sendable (String) -> Void) async throws {
        if manageSteamProcess {
            log("starting Steam; it downloads and installs the update, then restarts")
            _ = Shell.capture("/usr/bin/open", ["-a", paths.steamApp.path(percentEncoded: false)])
        }
        var deadline = Date().addingTimeInterval(installTimeout)
        var installed = SteamStatus(paths: paths.steam).clientBuild
        while installed != target {
            guard Date() < deadline else { throw SteamUpdateError.timedOut(installed: installed, target: target) }
            try await Task.sleep(for: .seconds(pollInterval))
            installed = SteamStatus(paths: paths.steam).clientBuild
        }
        log("Steam \(target) installed; waiting for the hook to load")
        deadline = Date().addingTimeInterval(hookTimeout)
        var verdict = SteamBuilds.localReport(paths: paths).verdict(for: target)
        // a session logs its counts over several seconds: broken can still turn into working
        while verdict != .working && Date() < deadline {
            try await Task.sleep(for: .seconds(pollInterval))
            verdict = SteamBuilds.localReport(paths: paths).verdict(for: target)
        }
        switch verdict {
        case .working: return
        case .broken(let why): throw SteamUpdateError.hookBroken(why)
        default: throw SteamUpdateError.hookBroken("Steam did not start with the hook within \(Int(hookTimeout / 60)) minutes")
        }
    }
}
