// Uninstall WovenGames: restore Steam, remove the compat tool, and clean up runtime data.

import Foundation

public enum UninstallerError: Error, CustomStringConvertible, Sendable {
    case gameRunning([String])
    /// Wine runs from an installed runner outside a Steam game (`woven run`)
    case runnerInUse
    case stepFailed(step: String, underlying: Error)

    public var description: String {
        switch self {
        case .gameRunning(let ids):
            return "cannot uninstall while games are running (app IDs: \(ids.joined(separator: ", "))); please quit them first"
        case .runnerInUse:
            return "a Wine program is running from WovenGames' engine (e.g. `woven run`); quit it first"
        case .stepFailed(let step, let error):
            return "uninstall failed during '\(step)': \(error)"
        }
    }
}

public struct Uninstaller: Sendable {
    public var paths: Paths
    public var deletePrefixes: Bool
    public var manageSteamProcess: Bool

    public init(paths: Paths = Paths(), deletePrefixes: Bool = false, manageSteamProcess: Bool = true) {
        self.paths = paths
        self.deletePrefixes = deletePrefixes
        self.manageSteamProcess = manageSteamProcess
    }

    public struct Plan: Sendable, Equatable {
        public var runningGames: [String]
        public var runnerInUse = false
        public var unpatchSteam: Bool
        public var unpinSteam: Bool
        public var removeCompatTool: Bool
        public var prefixesToDelete: [URL]
        public var removeSupport: Bool
        /// support/nonsteam holds the prefixes of games added outside Steam: kept like Steam's
        public var keepNonSteamPrefixes = false
        public var supportDir: URL
        public var developerTree: URL?
        public var developerTreeSize: Int64?

        public var isBlockedByRunningGames: Bool { !runningGames.isEmpty || runnerInUse }

        public var descriptions: [String] {
            var items: [String] = []
            if unpatchSteam {
                items.append("Restore original Steam.app configuration and remove hook")
            }
            if unpinSteam {
                items.append("Remove Steam update pin (allow Steam to update)")
            }
            if removeCompatTool {
                items.append("Remove compatibility tool link (wovengames-proton)")
            }
            for prefix in prefixesToDelete {
                items.append("Delete game prefix: \(prefix.path(percentEncoded: false))")
            }
            if removeSupport && keepNonSteamPrefixes {
                items.append("Remove application support directory except nonsteam/ (prefixes of games added outside Steam): \(supportDir.path(percentEncoded: false))")
            } else if removeSupport {
                items.append("Remove application support directory: \(supportDir.path(percentEncoded: false))")
            }
            return items
        }
    }

    /// Plans the uninstall operations without making changes.
    public func plan() -> Plan {
        let running = GameSessions(paths: paths).running()
        let status = SteamStatus(paths: paths.steam)
        let fm = FileManager.default

        let unpatchSteam = status.installed && status.injection == .wovenGames
        let unpinSteam = status.pin != .none

        let compatTool = paths.steam.compatTools.appending(path: "wovengames-proton")
        let removeCompatTool = fm.fileExists(atPath: compatTool.path(percentEncoded: false)) ||
            (try? fm.destinationOfSymbolicLink(atPath: compatTool.path(percentEncoded: false))) != nil

        var prefixesToDelete: [URL] = []
        if deletePrefixes {
            let library = SteamLibrary(paths: paths)
            for folder in library.folders() {
                let compatDataDir = folder.appending(path: "steamapps/compatdata")
                guard let items = try? fm.contentsOfDirectory(atPath: compatDataDir.path(percentEncoded: false)) else { continue }
                for item in items {
                    let gameCompat = compatDataDir.appending(path: item)
                    let runLog = gameCompat.appending(path: "wovengames-run.log")
                    if fm.fileExists(atPath: runLog.path(percentEncoded: false)) {
                        prefixesToDelete.append(gameCompat)
                    }
                }
            }
            prefixesToDelete.sort { $0.path < $1.path }
        }

        let removeSupport = fm.fileExists(atPath: paths.support.path(percentEncoded: false))

        let devTree = paths.home.appending(path: "Library/Developer/WovenGames")
        let devTreeExists = fm.fileExists(atPath: devTree.path(percentEncoded: false))
        let developerTree = devTreeExists ? devTree : nil
        let developerTreeSize = developerTree.map { Self.directorySize(at: $0) }

        return Plan(
            runningGames: running,
            runnerInUse: RunnerStore(paths: paths).inUse(),
            unpatchSteam: unpatchSteam,
            unpinSteam: unpinSteam,
            removeCompatTool: removeCompatTool,
            prefixesToDelete: prefixesToDelete,
            removeSupport: removeSupport,
            keepNonSteamPrefixes: !deletePrefixes && fm.fileExists(atPath: paths.support.appending(path: "nonsteam").path(percentEncoded: false)),
            supportDir: paths.support,
            developerTree: developerTree,
            developerTreeSize: developerTreeSize
        )
    }

    /// Executes the uninstallation. If a step fails, stops and throws without removing the support directory.
    public func run(plan: Plan? = nil, log: @Sendable (String) -> Void = { _ in }) throws {
        let currentPlan = plan ?? self.plan()
        guard currentPlan.runningGames.isEmpty else {
            throw UninstallerError.gameRunning(currentPlan.runningGames)
        }
        // removing the runner under a running Wine program crashes it
        guard !currentPlan.runnerInUse else { throw UninstallerError.runnerInUse }

        let fm = FileManager.default

        // 1. Unpatch Steam
        if currentPlan.unpatchSteam {
            do {
                log("unpatching Steam.app...")
                var patcher = SteamPatcher(paths: paths)
                patcher.manageSteamProcess = manageSteamProcess
                try patcher.unpatch(log: log)
            } catch {
                throw UninstallerError.stepFailed(step: "unpatch Steam", underlying: error)
            }
        }

        // 2. Unpin Steam
        if currentPlan.unpinSteam {
            do {
                log("unpinning Steam updates...")
                try SteamPatcher(paths: paths).unpin()
            } catch {
                throw UninstallerError.stepFailed(step: "unpin Steam", underlying: error)
            }
        }

        // 3. Remove compatibility tool folder/link if still there
        let compatTool = paths.steam.compatTools.appending(path: "wovengames-proton")
        if fm.fileExists(atPath: compatTool.path(percentEncoded: false)) ||
            (try? fm.destinationOfSymbolicLink(atPath: compatTool.path(percentEncoded: false))) != nil {
            do {
                log("removing compatibility tool...")
                try fm.removeItem(at: compatTool)
            } catch {
                throw UninstallerError.stepFailed(step: "remove compatibility tool", underlying: error)
            }
        }

        // 4. Delete game prefixes if requested
        for prefix in currentPlan.prefixesToDelete {
            do {
                log("deleting prefix \(prefix.path(percentEncoded: false))...")
                try fm.removeItem(at: prefix)
            } catch {
                throw UninstallerError.stepFailed(step: "delete prefix \(prefix.lastPathComponent)", underlying: error)
            }
        }

        // 5. Remove support folder
        if currentPlan.removeSupport && fm.fileExists(atPath: paths.support.path(percentEncoded: false)) {
            do {
                log("removing application support folder \(paths.support.path(percentEncoded: false))...")
                if currentPlan.keepNonSteamPrefixes {
                    let names = try fm.contentsOfDirectory(atPath: paths.support.path(percentEncoded: false))
                    for name in names where name != "nonsteam" {
                        try fm.removeItem(at: paths.support.appending(path: name))
                    }
                    log("kept \(paths.support.appending(path: "nonsteam").path(percentEncoded: false)) (games added outside Steam)")
                } else {
                    try fm.removeItem(at: paths.support)
                }
            } catch {
                throw UninstallerError.stepFailed(step: "remove application support folder", underlying: error)
            }
        }

        log("WovenGames runtime uninstalled")
        if let dev = currentPlan.developerTree, let size = currentPlan.developerTreeSize {
            log("note: engine build tree left intact at \(dev.path(percentEncoded: false)) (\(Self.formatBytes(size)))")
        }
    }

    public static func directorySize(at dir: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
