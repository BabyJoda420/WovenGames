// `woven setup`: lays the engine build out in ~/Library/Application Support/WovenGames the way
// the Steam hook (wovengames.dylib) and its compat tool run script expect it:
//
//   runners/<id>, runners/current                    the Wine runner
//   bridge/                                          Valve's Windows Steam DLLs, lsteamclient, steam.exe shim
//   signatures/macos.arm64/*.json                    where the hook finds its functions in Steam
//   wovengames.dylib, overlay-shim.dylib,            the hook and its helpers
//   iconmaker, appinfo, pe-d3d, syshud, dylib.version

import Foundation

public enum SetupError: Error, CustomStringConvertible {
    case missing(String, hint: String)

    public var description: String {
        switch self {
        case .missing(let what, let hint): "missing \(what) (\(hint))"
        }
    }
}

public struct EngineBuild: Sendable {
    /// engine/ (build-all.sh leaves a space-free symlink to it in the cache)
    public var root: URL

    public init(root: URL) { self.root = root }

    public static func locate(paths: Paths = Paths()) -> EngineBuild {
        EngineBuild(root: paths.home.appending(path: "Library/Caches/WovenGames/engine/root"))
    }

    var bridge: URL { root.appending(path: "build/bridge") }
    var helpers: URL { root.appending(path: "build/helpers") }
    var notProtonOut: URL { root.appending(path: "notproton/out") }
    var signatures: URL { root.appending(path: "notproton/signatures/macos.arm64") }
    var versionHeader: URL { root.appending(path: "notproton/dylib/version.h") }
    var dist: URL { root.appending(path: "dist/runners") }
    /// the repo's compat/ next to engine/ (resolve the cache symlink first, so ".." is the repo)
    var compatDatabase: URL { root.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "compat") }
}

public struct Setup: Sendable {
    public var paths: Paths
    public var engine: EngineBuild

    public init(paths: Paths = Paths(), engine: EngineBuild? = nil) {
        self.paths = paths
        self.engine = engine ?? EngineBuild.locate(paths: paths)
    }

    public var dylib: URL { paths.support.appending(path: "wovengames.dylib") }
    public var bridge: URL { paths.support.appending(path: "bridge") }

    /// Installs everything; `log` gets one line per step.
    public func run(runnerID: String = "selfbuilt-cx26.3-r1", log: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        let runnerSource = engine.dist.appending(path: runnerID)
        try require(runnerSource.appending(path: "runner.json"), "runner \(runnerID)", "engine/scripts/build-all.sh")
        try require(engine.notProtonOut.appending(path: "notproton.dylib"), "the Steam hook", "engine/scripts/build-all.sh")
        try require(engine.bridge.appending(path: "steamclient64.dll"), "Valve's bridge DLLs", "engine/scripts/fetch-valve-bridge.sh")

        let runner = try RunnerStore(paths: paths).install(from: runnerSource)
        _ = Shell.capture("/usr/bin/xattr", ["-dr", "com.apple.quarantine", runner.root.path(percentEncoded: false)])
        log("runner: \(runner.id) (selected)")

        for dir in ["legacycompat", "i386-windows", "x86_64-windows", "x86_64-unix"] {
            try fm.createDirectory(at: bridge.appending(path: dir), withIntermediateDirectories: true)
        }
        for name in ["steamclient.dll", "steamclient64.dll", "tier0_s64.dll", "vstdlib_s64.dll"] {
            try place(engine.bridge.appending(path: name), bridge.appending(path: name))
        }
        let legacy = engine.bridge.appending(path: "legacycompat")
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
        let sigFiles = ((try? fm.contentsOfDirectory(atPath: engine.signatures.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(".json") }
        for name in sigFiles { try place(engine.signatures.appending(path: name), sigs.appending(path: name)) }
        log("signatures: \(sigFiles.sorted().joined(separator: ", "))")

        try place(engine.notProtonOut.appending(path: "overlay-shim.dylib"), paths.support.appending(path: "overlay-shim.dylib"))
        try place(engine.notProtonOut.appending(path: "iconmaker"), paths.support.appending(path: "iconmaker"))
        try place(engine.notProtonOut.appending(path: "appinfo"), paths.support.appending(path: "appinfo"))
        try place(engine.helpers.appending(path: "pe-d3d"), paths.support.appending(path: "pe-d3d"))
        try place(engine.helpers.appending(path: "syshud"), paths.support.appending(path: "syshud"))
        try place(engine.notProtonOut.appending(path: "notproton.dylib"), dylib)
        let version = (try? String(contentsOf: engine.versionHeader, encoding: .utf8))
            .flatMap { $0.firstMatch(of: try! Regex(#"VERSION\s+"([^"]+)""#))?.output[1].substring }
            .map(String.init) ?? "unknown"
        try (version + "\n").write(to: paths.support.appending(path: "dylib.version"), atomically: true, encoding: .utf8)
        log("hook \(version) and helpers: \(paths.support.path(percentEncoded: false))")

        let compat = paths.support.appending(path: "compat")
        try fm.createDirectory(at: compat, withIntermediateDirectories: true)
        let entries = ((try? fm.contentsOfDirectory(atPath: engine.compatDatabase.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(".env") }
        for name in entries { try place(engine.compatDatabase.appending(path: name), compat.appending(path: name)) }
        log("compat database: \(entries.count) game(s)")
    }

    func require(_ url: URL, _ what: String, _ hint: String) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw SetupError.missing(what, hint: hint)
        }
    }

    /// Copies via a temporary name, so a running reader never sees half a file.
    func place(_ source: URL, _ dest: URL) throws {
        try require(source, source.lastPathComponent, "engine/scripts/build-all.sh")
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        _ = try fm.replaceItemAt(dest, withItemAt: tmp)
    }
}
