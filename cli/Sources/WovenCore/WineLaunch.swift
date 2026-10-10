// The environment a game runs with: the same variables the compat tool's run script exports

import Foundation

public struct WineLaunch: Sendable {
    public var runner: Runner
    public var prefix: URL
    public var backend: Backend
    /// msync: on by default for self-built runners, whose wineserver carries the msync fixes
    public var msync = true
    /// Apple's Metal Performance HUD
    public var hud = false
    /// WINEDEBUG; nil keeps the run script's default
    public var debug: String?

    public init(runner: Runner, prefix: URL, backend: Backend) {
        self.runner = runner
        self.prefix = prefix
        self.backend = backend
    }

    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        // nothing from an outer Wine session may leak in
        for key in env.keys where key.hasPrefix("WINE") || key.hasPrefix("DXMT_") || key.hasPrefix("D3DM_") {
            env.removeValue(forKey: key)
        }
        let root = runner.root.path(percentEncoded: false)
        env["WINEPREFIX"] = prefix.path(percentEncoded: false)
        env["WINELOADER"] = runner.loader.path(percentEncoded: false)
        env["WINESERVER"] = runner.server.path(percentEncoded: false)
        env["WINEDLLPATH"] = "\(root)/lib/wine/x86_64-windows:\(runner.wineUnix.path(percentEncoded: false))"
        env["WINEMSYNC"] = msync ? "1" : "0"
        env["WINEDEBUG"] = debug ?? "err+all,fixme-all"
        env["PATH"] = "\(root)/bin:" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(root)/lib:/usr/local/lib:/usr/lib"

        if let dir = backend.rendererDir {
            env["WINEDLLPATH_PREPEND"] = "\(root)/\(dir)"
        }
        if backend == .d3dmetal {
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = runner.d3dShared.path(percentEncoded: false)
        }
        env["CX_ACTIVE_GRAPHICS_BACKEND"] = backend.rawValue

        if hud {
            env["MTL_HUD_ENABLED"] = "1"
            env["MTL_HUD_ALIGNMENT"] = env["MTL_HUD_ALIGNMENT"] ?? "topright"
            env["MTL_HUD_SCALE"] = env["MTL_HUD_SCALE"] ?? "0.12"
            env["MTL_HUD_OPACITY"] = env["MTL_HUD_OPACITY"] ?? "0.85"
            env["MTL_HUD_ELEMENTS"] = env["MTL_HUD_ELEMENTS"]
                ?? "fps,frameinterval,gputime,presentdelay,layersize,memory,fpsgraph"
        }
        return env
    }

    /// Runs `wine <arguments>` and returns its exit status.
    public func run(_ arguments: [String], log: URL? = nil) throws -> Int32 {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        return try Shell.run(runner.loader, arguments, environment: environment(), log: log)
    }

    /// Waits for every process in this prefix to exit (or, with `kill`, ends them).
    public func waitForServer(kill: Bool = false) {
        _ = Shell.capture(runner.server.path(percentEncoded: false), [kill ? "-k" : "-w"], environment: environment())
    }
}
