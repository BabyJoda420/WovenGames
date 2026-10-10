// `woven doctor`: is this Mac ready to play?

import Foundation

public struct Check: Sendable {
    public enum Level: String, Sendable { case ok, info, warn, fail }
    public var level: Level
    public var title: String
    public var detail: String
}

public enum Doctor {
    public static func run(paths: Paths = Paths()) -> [Check] {
        var checks: [Check] = []
        func add(_ level: Check.Level, _ title: String, _ detail: String) {
            checks.append(Check(level: level, title: title, detail: detail))
        }

        // Hardware and OS
        let arm = Shell.capture("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        add(arm ? .ok : .fail, "Apple Silicon", arm ? "arm64" : "WovenGames needs an Apple Silicon Mac")

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        add(os.majorVersion >= 14 ? .ok : .fail, "macOS", os.majorVersion >= 14 ? osText : "\(osText); macOS 14 or later is required")

        let rosetta = Shell.capture("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]).status == 0
        add(rosetta ? .ok : .fail, "Rosetta 2", rosetta ? "installed" : "missing: softwareupdate --install-rosetta")

        if let free = try? paths.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let gb = Double(free) / 1_000_000_000
            add(gb >= 20 ? .ok : .warn, "Free disk space", String(format: "%.0f GB", gb) + (gb >= 20 ? "" : " (games need room)"))
        }

        // Runner
        let store = RunnerStore(paths: paths)
        if let runner = try? store.current() {
            add(.ok, "Runner", "\(runner.id) (\(runner.manifest.wine ?? "?"))")
            for backend in Backend.allCases where backend.rendererDir != nil {
                add(runner.has(backend) ? .ok : .warn, "  \(backend.rawValue)", runner.has(backend) ? "present" : "missing from this runner")
            }
        } else {
            let built = (try? FileManager.default.contentsOfDirectory(atPath: paths.engineDist.path(percentEncoded: false))) ?? []
            add(.fail, "Runner", built.isEmpty
                ? "none installed; build one with engine/scripts/build-all.sh"
                : "none installed; built: \(built.joined(separator: ", ")); run `woven runner install`")
        }

        // Steam
        let steam = SteamStatus(paths: paths.steam)
        if !steam.installed {
            add(.fail, "Steam", "not installed in /Applications")
        } else {
            add(.ok, "Steam", "client build \(steam.clientBuild ?? "unknown")\(steam.running ? ", running" : "")")
            let builds = SteamBuilds.localReport(paths: paths)
            switch builds.verdict(for: steam.clientBuild) {
            case .working: add(.ok, "  Build support", "the hook works on this build")
            case .checkedOffline: add(.ok, "  Build support", "checked offline; start Steam once to confirm")
            case .broken(let why): add(.fail, "  Build support", "the hook failed on this build (\(why)); `woven steam unpatch` or wait for an update")
            case .failsOffline(let n): add(.fail, "  Build support", "this build is not supported (\(n) signatures missing)")
            case .unchecked: add(.warn, "  Build support", "this build has not been checked; start Steam once, then run `woven steam builds`")
            }
            if let pending = steam.pendingBuild {
                let v = builds.verdict(for: pending)
                add(v.isSafe ? .info : .warn, "  Pending update",
                    "build \(pending) is downloaded but not applied (\(v.label))\(v.isSafe ? "" : "; keep Steam pinned")")
            }
            switch steam.injection {
            case .none: add(.info, "  Steam Play hook", "not installed (`woven setup`, then `woven steam patch`)")
            case .wovenGames:
                if SteamPatcher(paths: paths).deployedHookIsCurrent {
                    add(.ok, "  Steam Play hook", "WovenGames")
                } else {
                    add(.warn, "  Steam Play hook", "Steam carries an older hook; run `woven steam patch` (restarts Steam)")
                }
            case .notProton: add(.info, "  Steam Play hook", "NotProton is installed; `woven steam patch` takes it over")
            case .other(let lib): add(.warn, "  Steam Play hook", "unknown library injected: \(lib)")
            }
            switch steam.pin {
            case .full: add(.warn, "  Update pin", "BootStrapperInhibitAll: Steam never updates, which can stop it from signing in; prefer `woven steam pin`")
            case .onLaunchOnly: add(.ok, "  Update pin", "Steam does not update at launch")
            case .none: add(steam.injection == .wovenGames ? .warn : .info, "  Update pin",
                            "none; a Steam update can break the hook (`woven steam pin`)")
            }
        }

        if FileManager.default.fileExists(atPath: paths.notProtonSupport.path(percentEncoded: false)) {
            add(.info, "NotProton data", paths.notProtonSupport.path(percentEncoded: false))
        }
        return checks
    }
}
