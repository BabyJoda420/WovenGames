// Injecting the hook into macOS Steam, and taking it out again
//
// Steam.app's Info.plist gets LSEnvironment DYLD_INSERT_LIBRARIES pointing at
// Contents/MacOS/wovengames.dylib. The bootstrapper carries the hardened runtime, which drops
// DYLD_INSERT_LIBRARIES, so Steam.app is re-signed ad hoc (replacing Valve's signature).
// Writing into /Applications/Steam.app needs the App Management permission for the app that
// runs this (System Settings > Privacy & Security > App Management).

import CryptoKit
import Foundation

public enum SteamPatchError: Error, CustomStringConvertible {
    case steamMissing
    case notSetUp
    case stillRunning
    case foreignInsert(String)
    case plist(String)
    case command(String, String)
    /// macOS refused: App Management is off for the app running this
    case appManagementDenied
    case notWritable(String)

    public var description: String {
        switch self {
        case .steamMissing: "Steam is not installed in /Applications"
        case .notSetUp: "the hook is not installed yet; run `woven setup` first"
        case .stillRunning: "Steam is still running; quit it and retry"
        case .foreignInsert(let lib): "Steam already injects \(lib), which is not WovenGames or NotProton; not touching it"
        case .plist(let why): "could not update Steam's Info.plist: \(why)"
        case .command(let cmd, let out): "\(cmd) failed: \(out)\nIf this is a permission error, allow your terminal under System Settings > Privacy & Security > App Management."
        case .appManagementDenied:
            "macOS did not allow changing Steam.app. Turn on the app you ran this from (WovenGames, or your terminal for `woven`) under System Settings > Privacy & Security > App Management, then try again."
        case .notWritable(let why): "Steam.app cannot be changed (\(why)). Is it owned by another user? Reinstall Steam from steampowered.com as yourself."
        }
    }
}

public struct SteamPatcher: Sendable {
    public var paths: Paths
    /// false in tests: never look for or quit the real Steam
    public var manageSteamProcess = true
    static let insertKey = "DYLD_INSERT_LIBRARIES"
    // NotProton keeps SDL away from the Mac's built-in Apple keyboard/trackpad HID device
    static let controllerBlockKey = "SDL_JOYSTICK_BLACKLIST_DEVICES"
    static let controllerBlockValue = "0x05ac/0x0004"

    public init(paths: Paths = Paths()) { self.paths = paths }

    var steam: SteamPaths { paths.steam }
    var macOS: URL { steam.app.appending(path: "Contents/MacOS") }
    public var deployedDylib: URL { macOS.appending(path: "wovengames.dylib") }
    var notProtonDylib: URL { macOS.appending(path: "notproton.dylib") }
    var backups: URL { paths.support.appending(path: "backups") }
    /// Steam's Info.plist as it was before any hook (ours or NotProton's)
    public var originalPlist: URL { backups.appending(path: "Info.plist.original") }
    var notProtonBackup: URL { paths.notProtonSupport.appending(path: "backups/Info.plist.before-notproton") }

    // MARK: patch

    public func patch(log: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: steam.app.path(percentEncoded: false)) else { throw SteamPatchError.steamMissing }
        let source = paths.support.appending(path: "wovengames.dylib")
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { throw SteamPatchError.notSetUp }
        try checkAccess()
        try quitSteam(log: log)
        do {
            try patchQuitSteam(source: source, log: log)
        } catch let error where AppManagement.isDenial(error) {
            throw SteamPatchError.appManagementDenied
        }
    }

    /// Fails early, before Steam is quit, when macOS will not let us change Steam.app.
    public func checkAccess() throws {
        switch AppManagement.probe(steamApp: steam.app) {
        case .granted: return
        case .denied: throw SteamPatchError.appManagementDenied
        case .notWritable(let why): throw SteamPatchError.notWritable(why)
        case .steamMissing: throw SteamPatchError.steamMissing
        }
    }

    func patchQuitSteam(source: URL, log: (String) -> Void) throws {
        let fm = FileManager.default

        var plist = try readPlist()
        var env = plist["LSEnvironment"] as? [String: Any] ?? [:]
        let current = env[Self.insertKey] as? String ?? ""
        let ours = deployedDylib.path(percentEncoded: false)
        let takingOver = current.contains("notproton.dylib")
        guard current.isEmpty || current == ours || takingOver else { throw SteamPatchError.foreignInsert(current) }

        try saveOriginal(currentPlist: plist, hadInsert: !current.isEmpty, log: log)

        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try? fm.removeItem(at: deployedDylib)
        try fm.copyItem(at: source, to: deployedDylib)
        try (Self.sha256(of: source) ?? "").write(to: deployedHashFile, atomically: true, encoding: .utf8)
        if takingOver {
            try? fm.removeItem(at: notProtonDylib)
            log("took over from NotProton (removed notproton.dylib from Steam.app)")
        }

        env[Self.insertKey] = ours
        env[Self.controllerBlockKey] = Self.controllerBlockValue
        plist["LSEnvironment"] = env
        try writePlist(plist)
        try resign(log: log)
        log("Steam patched: \(ours)")
    }

    /// false when Steam.app carries an older hook than the one `woven setup` installed.
    /// `patch` records the hash of the hook it deployed (re-signing changes the deployed copy).
    public var deployedHookIsCurrent: Bool {
        guard FileManager.default.fileExists(atPath: deployedDylib.path(percentEncoded: false)),
              let installed = Self.sha256(of: paths.support.appending(path: "wovengames.dylib")) else { return true }
        let recorded = (try? String(contentsOf: deployedHashFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return recorded == installed
    }

    var deployedHashFile: URL { paths.support.appending(path: "deployed-hook.sha256") }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: unpatch

    public func unpatch(log: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: steam.app.path(percentEncoded: false)) else { throw SteamPatchError.steamMissing }
        try checkAccess()
        try quitSteam(log: log)
        if let data = try? Data(contentsOf: originalPlist) {
            try data.write(to: steam.infoPlist)
            log("restored Info.plist from \(originalPlist.path(percentEncoded: false))")
        } else {
            var plist = try readPlist()
            var env = plist["LSEnvironment"] as? [String: Any] ?? [:]
            env.removeValue(forKey: Self.insertKey)
            env.removeValue(forKey: Self.controllerBlockKey)
            plist["LSEnvironment"] = env
            try writePlist(plist)
            log("removed the insert from Info.plist (no backup found)")
        }
        try? fm.removeItem(at: deployedDylib)
        try? fm.removeItem(at: notProtonDylib)
        try? fm.removeItem(at: steam.compatTools.appending(path: "wovengames-proton"))
        try resign(log: log)
        log("Steam restored (ad-hoc signed; reinstall Steam from steampowered.com for Valve's own signature)")
    }

    // MARK: update pin

    static let pinKey = "BootStrapperInhibitUpdateOnLaunch"
    var pinFiles: [URL] { [steam.configFile, steam.innerClient.appending(path: "steam.cfg")] }

    /// Stops the bootstrapper from updating Steam at launch, which would replace the build the
    /// hook's signatures were made for. (The same setting NotProton uses.)
    public func pin() throws {
        for url in pinFiles {
            let lines = (try? String(contentsOf: url, encoding: .utf8)).map(Self.lines) ?? []
            let kept = lines.filter { Self.key(of: $0) != Self.pinKey.lowercased() }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ((kept + ["\(Self.pinKey)=enable"]).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Lets Steam update again. Removes only the pin setting and leaves other lines alone.
    public func unpin() throws {
        for url in pinFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let kept = Self.lines(text).filter {
                let k = Self.key(of: $0)
                return k != Self.pinKey.lowercased() && k != "bootstrapperinhibitall"
            }
            if kept.isEmpty {
                try FileManager.default.removeItem(at: url)
            } else {
                try (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func key(of line: String) -> String {
        String(line.split(separator: "=", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: helpers

    func saveOriginal(currentPlist: [String: Any], hadInsert: Bool, log: (String) -> Void) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: originalPlist.path(percentEncoded: false)) else { return }
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        if fm.fileExists(atPath: notProtonBackup.path(percentEncoded: false)) {
            try fm.copyItem(at: notProtonBackup, to: originalPlist)
            log("backup: NotProton's pristine Info.plist -> \(originalPlist.path(percentEncoded: false))")
        } else if !hadInsert {
            try fm.copyItem(at: steam.infoPlist, to: originalPlist)
            log("backup: \(originalPlist.path(percentEncoded: false))")
        } else {
            // the best we can do: the current plist without the insert
            var clean = currentPlist
            var env = clean["LSEnvironment"] as? [String: Any] ?? [:]
            env.removeValue(forKey: Self.insertKey)
            env.removeValue(forKey: Self.controllerBlockKey)
            clean["LSEnvironment"] = env
            let data = try PropertyListSerialization.data(fromPropertyList: clean, format: .xml, options: 0)
            try data.write(to: originalPlist)
            log("backup (reconstructed): \(originalPlist.path(percentEncoded: false))")
        }
    }

    func readPlist() throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: steam.infoPlist)
            guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw SteamPatchError.plist("not a dictionary")
            }
            return dict
        } catch let error as SteamPatchError {
            throw error
        } catch {
            throw SteamPatchError.plist("\(error)")
        }
    }

    func writePlist(_ dict: [String: Any]) throws {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: steam.infoPlist, options: .atomic)
        } catch {
            throw SteamPatchError.plist("\(error)")
        }
    }

    func resign(log: (String) -> Void) throws {
        var targets = [macOS.appending(path: "steam_osx"), steam.app]
        if FileManager.default.fileExists(atPath: deployedDylib.path(percentEncoded: false)) {
            targets.insert(deployedDylib, at: 0)
        }
        for target in targets {
            let r = Shell.capture("/usr/bin/codesign", ["-f", "-s", "-", target.path(percentEncoded: false)])
            guard r.status == 0 else { throw SteamPatchError.command("codesign \(target.lastPathComponent)", r.output) }
        }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = Shell.capture(lsregister, ["-f", steam.app.path(percentEncoded: false)])
        log("re-signed Steam.app (ad hoc)")
    }

    func quitSteam(log: (String) -> Void) throws {
        guard manageSteamProcess else { return }
        func running() -> Bool { Shell.capture("/usr/bin/pgrep", ["-x", "steam_osx"]).status == 0 }
        guard running() else { return }
        log("quitting Steam...")
        _ = Shell.capture("/usr/bin/osascript", ["-e", "quit app \"Steam\""])
        for _ in 0..<60 where running() { Thread.sleep(forTimeInterval: 0.5) }
        if running() { throw SteamPatchError.stillRunning }
    }
}
