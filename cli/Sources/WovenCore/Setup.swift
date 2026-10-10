// Installing the engine into ~/Library/Application Support/WovenGames, laid out the way the
// Steam hook (wovengames.dylib) and its compat tool run script expect it:
//
//   runners/<id>, runners/current                    the Wine runner
//   bridge/                                          Valve's Windows Steam DLLs, lsteamclient, steam.exe shim
//   signatures/macos.arm64/*.json                    where the hook finds its functions in Steam
//   compat/<appid>.env                               known-good per-game settings
//   wovengames.dylib, overlay-shim.dylib,            the hook and its helpers
//   iconmaker, appinfo, pe-d3d, syshud, dylib.version
//
// The files come from a Payload: either a local engine build (`woven setup`) or an unpacked
// release plus what ReleaseInstaller downloads on this Mac (`woven install`).

import Foundation

public enum SetupError: Error, CustomStringConvertible {
    case missing(String, hint: String)

    public var description: String {
        switch self {
        case .missing(let what, let hint): "missing \(what) (\(hint))"
        }
    }
}

/// Where each part of the engine comes from.
public struct Payload: Sendable {
    public var runner: URL
    public var hook: URL
    /// overlay-shim.dylib, iconmaker, appinfo, pe-d3d, syshud
    public var helpers: [String: URL]
    public var signatures: URL
    public var compat: URL
    /// steamclient(64).dll, tier0_s64.dll, vstdlib_s64.dll, legacycompat/
    public var valveBridge: URL
    public var hookVersion: String
    /// how to get a missing file, for error messages
    public var hint: String
}

public struct EngineBuild: Sendable {
    /// engine/ (build-all.sh leaves a space-free symlink to it in the cache)
    public var root: URL

    public init(root: URL) { self.root = root }

    public static func locate(paths: Paths = Paths()) -> EngineBuild {
        EngineBuild(root: paths.home.appending(path: "Library/Caches/WovenGames/engine/root"))
    }

    var dist: URL { root.appending(path: "dist/runners") }

    public func payload(runnerID: String = "selfbuilt-cx26.3-r1") -> Payload {
        let out = root.appending(path: "notproton/out")
        let helpers = root.appending(path: "build/helpers")
        let header = (try? String(contentsOf: root.appending(path: "notproton/dylib/version.h"), encoding: .utf8)) ?? ""
        return Payload(
            runner: dist.appending(path: runnerID),
            hook: out.appending(path: "notproton.dylib"),
            helpers: ["overlay-shim.dylib": out.appending(path: "overlay-shim.dylib"),
                      "iconmaker": out.appending(path: "iconmaker"),
                      "appinfo": out.appending(path: "appinfo"),
                      "pe-d3d": helpers.appending(path: "pe-d3d"),
                      "syshud": helpers.appending(path: "syshud")],
            signatures: root.appending(path: "notproton/signatures/macos.arm64"),
            // the repo's compat/ next to engine/ (resolve the cache symlink first, so ".." is the repo)
            compat: root.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "compat"),
            valveBridge: root.appending(path: "build/bridge"),
            hookVersion: header.firstMatch(of: try! Regex(#"VERSION\s+"([^"]+)""#))?.output[1].substring.map(String.init) ?? "unknown",
            hint: "engine/scripts/build-all.sh")
    }
}

public struct Setup: Sendable {
    public var paths: Paths
    public var payload: Payload

    public init(paths: Paths = Paths(), payload: Payload? = nil) {
        self.paths = paths
        self.payload = payload ?? EngineBuild.locate(paths: paths).payload()
    }

    public var dylib: URL { paths.support.appending(path: "wovengames.dylib") }
    public var bridge: URL { paths.support.appending(path: "bridge") }

    /// Installs everything; `log` gets one line per step.
    public func run(log: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        try require(payload.runner.appending(path: "runner.json"), "the Wine runner")
        try require(payload.hook, "the Steam hook")
        try require(payload.valveBridge.appending(path: "steamclient64.dll"), "Valve's bridge DLLs")

        let runner = try RunnerStore(paths: paths).install(from: payload.runner)
        _ = Shell.capture("/usr/bin/xattr", ["-dr", "com.apple.quarantine", runner.root.path(percentEncoded: false)])
        log("runner: \(runner.id) (selected)")

        for dir in ["legacycompat", "i386-windows", "x86_64-windows", "x86_64-unix"] {
            try fm.createDirectory(at: bridge.appending(path: dir), withIntermediateDirectories: true)
        }
        for name in ["steamclient.dll", "steamclient64.dll", "tier0_s64.dll", "vstdlib_s64.dll"] {
            try place(payload.valveBridge.appending(path: name), bridge.appending(path: name))
        }
        let legacy = payload.valveBridge.appending(path: "legacycompat")
        for name in (try? fm.contentsOfDirectory(atPath: legacy.path(percentEncoded: false))) ?? [] {
            try place(legacy.appending(path: name), bridge.appending(path: "legacycompat/\(name)"))
        }
        let wine = runner.root.appending(path: "lib/wine")
        try place(runner.root.appending(path: "share/steamplay/steam.exe"), bridge.appending(path: "steam.exe"))
        try place(wine.appending(path: "x86_64-windows/lsteamclient.dll"), bridge.appending(path: "lsteamclient.dll"))
        try place(wine.appending(path: "x86_64-windows/lsteamclient.dll"), bridge.appending(path: "x86_64-windows/lsteamclient.dll"))
        try place(wine.appending(path: "i386-windows/lsteamclient.dll"), bridge.appending(path: "i386-windows/lsteamclient.dll"))
        let so = bridge.appending(path: "x86_64-unix/lsteamclient.so")
        try place(wine.appending(path: "x86_64-unix/lsteamclient.so"), so)
        _ = Shell.capture("/usr/bin/codesign", ["--remove-signature", so.path(percentEncoded: false)])
        // A CrossOver-era bridge kept binary-patched ntdlls here; they do not belong to this runner.
        try? fm.removeItem(at: bridge.appending(path: "wine"))
        log("bridge: \(bridge.path(percentEncoded: false))")

        let sigs = paths.support.appending(path: "signatures/macos.arm64")
        try fm.createDirectory(at: sigs, withIntermediateDirectories: true)
        let sigFiles = files(in: payload.signatures, suffix: ".json")
        for name in sigFiles { try place(payload.signatures.appending(path: name), sigs.appending(path: name)) }
        log("signatures: \(sigFiles.joined(separator: ", "))")

        for (name, source) in payload.helpers.sorted(by: { $0.key < $1.key }) {
            try place(source, paths.support.appending(path: name))
        }
        try place(payload.hook, dylib)
        try (payload.hookVersion + "\n").write(to: paths.support.appending(path: "dylib.version"), atomically: true, encoding: .utf8)
        log("hook \(payload.hookVersion) and helpers: \(paths.support.path(percentEncoded: false))")

        let compat = paths.support.appending(path: "compat")
        try fm.createDirectory(at: compat, withIntermediateDirectories: true)
        let entries = files(in: payload.compat, suffix: ".env")
        for name in entries { try place(payload.compat.appending(path: name), compat.appending(path: name)) }
        log("compat database: \(entries.count) game(s)")
    }

    func files(in dir: URL, suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(suffix) }.sorted()
    }

    func require(_ url: URL, _ what: String) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw SetupError.missing(what, hint: payload.hint)
        }
    }

    /// Copies via a temporary name, so a running reader never sees half a file.
    func place(_ source: URL, _ dest: URL) throws {
        try require(source, source.lastPathComponent)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        _ = try fm.replaceItemAt(dest, withItemAt: tmp)
    }
}
