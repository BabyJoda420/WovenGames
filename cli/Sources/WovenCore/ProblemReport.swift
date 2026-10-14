// "Report a Problem": what a maintainer needs to understand an issue, in one zip.
//
// Collected: versions, the Mac, the Steam state, Doctor's checks, the app's and the hook's
// logs, each game's last launches and its settings. Removed before anything is written: the
// home folder path, the macOS user name, Steam account names, Steam IDs and email addresses.
// The user reviews the folder before attaching the zip to an issue; nothing is uploaded.

import Foundation

public struct Redactor: Sendable {
    /// literal text -> replacement, longest first so a path wins over the name inside it
    var literals: [(String, String)]

    public init(paths: Paths = Paths(), extra: [(String, String)] = []) {
        var pairs: [(String, String)] = [(paths.home.path(percentEncoded: false).trimmingSuffix("/"), "~")]
        for (name, label) in [(NSUserName(), "<user>"), (NSFullUserName(), "<user>")] where name.count >= 3 {
            pairs.append((name, label))
        }
        let login = paths.steam.userData.appending(path: "config/loginusers.vdf")
        if let text = try? String(contentsOf: login, encoding: .utf8) {
            for (steamID, user) in VDF.parse(text)["users"]?.pairs ?? [] {
                pairs.append((steamID, "<steamid>"))
                if let account = user["AccountName"]?.string, account.count >= 3 { pairs.append((account, "<steam account>")) }
                if let persona = user["PersonaName"]?.string, persona.count >= 3 { pairs.append((persona, "<steam name>")) }
            }
        }
        // userdata/<account id>
        let userdata = paths.steam.userData.appending(path: "userdata")
        for id in (try? FileManager.default.contentsOfDirectory(atPath: userdata.path(percentEncoded: false))) ?? []
        where id.count >= 4 && id.allSatisfy(\.isNumber) {
            pairs.append((id, "<steam account id>"))
        }
        literals = (pairs + extra).sorted { $0.0.count > $1.0.count }
    }

    public func clean(_ text: String) -> String {
        // Steam's environment in the run log names the account, whether or not loginusers.vdf does
        var out = text.replacing(try! Regex(#"\b(SteamUser|SteamAppUser)=[^\s"'<]+"#)) { match in
            "\(match.output[1].substring ?? "SteamUser")=<steam account>"
        }
        for (find, replace) in literals where !find.isEmpty {
            out = out.replacingOccurrences(of: find, with: replace, options: .caseInsensitive)
        }
        out = out.replacing(try! Regex(#"7656119\d{10}"#), with: "<steamid>")
        out = out.replacing(try! Regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), with: "<email>")
        return out
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}

public struct ProblemReport: Sendable {
    public var paths: Paths
    public var appVersion: String
    /// the user's own words, written into summary.txt
    public var description: String

    public init(paths: Paths = Paths(), appVersion: String, description: String = "") {
        self.paths = paths
        self.appVersion = appVersion
        self.description = description
    }

    public struct Output: Sendable {
        /// the folder to review
        public var folder: URL
        /// the same files zipped, to attach to a GitHub issue
        public var zip: URL
    }

    /// Writes the report into `directory` (a folder and a zip of it).
    public func write(to directory: URL, now: Date = Date()) throws -> Output {
        let redactor = Redactor(paths: paths)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let name = "WovenGames-report-\(stamp.string(from: now))"
        let folder = directory.appending(path: name)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        func put(_ relative: String, _ text: String) throws {
            let url = folder.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try redactor.clean(text).write(to: url, atomically: true, encoding: .utf8)
        }
        func tail(_ url: URL, lines: Int) -> String? {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let all = text.split(separator: "\n", omittingEmptySubsequences: false)
            return all.suffix(lines).joined(separator: "\n")
        }

        try put("summary.txt", summary())
        if let log = tail(paths.logs.appending(path: "app.log"), lines: 1500) { try put("logs/app.log", log) }
        if let log = tail(paths.hookLog, lines: 3000) { try put("logs/steam-hook.log", log) }

        let games = SteamLibrary(paths: paths).windowsGames()
        for game in games {
            let dir = "games/\(game.appID) \(game.name.filter { !"/:\\".contains($0) })"
            var about = "\(game.name) (app \(game.appID))\n"
            about += "install folder: \(game.installDir.lastPathComponent)\n"
            if let options = SteamLaunchOptions.read(appID: game.appID, paths: paths) { about += "Steam launch options: \(options.raw)\n" }
            about += "settings (games/\(game.appID).env):\n\(GameSettings.load(appID: game.appID, paths: paths).text)"
            if let rec = GameSettings.recommended(appID: game.appID, paths: paths) { about += "recommended (compat/\(game.appID).env):\n\(rec.text)" }
            try put("\(dir)/about.txt", about)
            if let log = tail(game.runLog, lines: 2500) { try put("\(dir)/launch.log", log) }
            let wine = paths.support.appending(path: "launchers/\(game.appID)/wovengames-wine.log")
            if let log = tail(wine, lines: 2000) { try put("\(dir)/wine.log", log) }
        }
        if let global = try? String(contentsOf: paths.support.appending(path: "global.env"), encoding: .utf8) {
            try put("settings/global.env", global)
        }

        let zip = directory.appending(path: "\(name).zip")
        try? fm.removeItem(at: zip)
        // --norsrc: no AppleDouble "._" copies of the files' extended attributes in the zip
        let r = Shell.capture("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", folder.path(percentEncoded: false), zip.path(percentEncoded: false)])
        guard r.status == 0 else { throw ReleaseError.badRelease("could not zip the report: \(r.output)") }
        return Output(folder: folder, zip: zip)
    }

    func summary() -> String {
        var s = "WovenGames problem report\n\n"
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "What happened:\n\(description)\n\n"
        }
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        s += "app: \(appVersion)\n"
        s += "engine: \(read(paths.engineVersionFile) ?? "unknown")\n"
        s += "hook: \(read(paths.support.appending(path: "dylib.version")) ?? "unknown")\n"
        if let runner = try? RunnerStore(paths: paths).current() {
            s += "runner: \(runner.id) \(runner.manifest.wine ?? "") renderers \(runner.manifest.renderers.map { $0.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") } ?? "")\n"
            s += "D3DMetal downloaded: \(runner.has(.d3dmetal) ? "yes" : "no")\n"
        }
        s += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        s += "Mac: \(Shell.capture("/usr/sbin/sysctl", ["-n", "hw.model"]).output.trimmingCharacters(in: .whitespacesAndNewlines)), "
        s += "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, \(ProcessInfo.processInfo.activeProcessorCount) cores\n"
        let steam = SteamStatus(paths: paths.steam)
        s += "Steam: build \(steam.clientBuild ?? "unknown")\(steam.pendingBuild.map { ", update \($0) downloaded" } ?? ""), hook \(steam.injection), pin \(steam.pin), \(steam.running ? "running" : "not running")\n"
        if let session = SteamBuilds.localReport(paths: paths).session {
            s += "last Steam start: \(session.started.map { "\($0)" } ?? "?"), signatures \(session.signatures.map { "\($0.done)/\($0.total)" } ?? "-"), hooks \(session.hooks.map { "\($0.done)/\($0.total)" } ?? "-")\n"
        }
        s += "\nChecks:\n"
        for check in Doctor.run(paths: paths) {
            s += "  [\(check.level.rawValue)] \(check.title.trimmingCharacters(in: .whitespaces)): \(check.detail)\n"
        }
        return s
    }
}
