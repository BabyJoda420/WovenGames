// Graphics backend selection (the same rules as the compat tool's run script, detect_d3d)

import Foundation

public enum Backend: String, CaseIterable, Sendable {
    case d3dmetal  // Apple D3DMetal: D3D11/D3D12 -> Metal
    case dxmt      // DXMT: D3D10/D3D11 -> Metal
    case wined3d   // Wine's own: D3D1-11 -> OpenGL

    /// Directory prepended to Wine's DLL search path, relative to the runner root.
    var rendererDir: String? {
        switch self {
        case .d3dmetal: "lib/renderers/d3dmetal"
        case .dxmt: "lib/renderers/dxmt"
        case .wined3d: nil
        }
    }
}

/// The graphics API a game renders with, as far as its binaries tell.
public enum DetectedAPI: String, Sendable {
    case d3d12, d3d11, d3d9, opengl, vulkan, none

    public var backend: Backend {
        switch self {
        case .d3d12: .d3dmetal
        case .d3d11: .dxmt
        default: .wined3d
        }
    }
}

public struct BackendDetection: Sendable {
    public var api: DetectedAPI
    public var backend: Backend { api.backend }
    /// What was looked at, for logs and `woven backend detect`.
    public var notes: [String] = []
}

public enum BackendDetector {
    static let maxDepth = 6
    static let skippedDirs = try! Regex(
        "/(_commonredist|commonredist|redist|redistributables|directx|vcredist|dotnet|support|easyanticheat|battleye|__installer|installers?|crashreport[a-z]*)/"
    ).ignoresCase()
    static let agilityCore = try! Regex("/d3d12/(d3d12core|d3d12sdklayers)\\.dll$").ignoresCase()

    /// - Parameters:
    ///   - launchTarget: the executable being started, if known
    ///   - installDir: the game's install folder
    public static func detect(launchTarget: URL?, installDir: URL) -> BackendDetection {
        var notes: [String] = []
        let files = gameFiles(in: installDir)

        // A game that ships Microsoft's D3D12 Agility SDK renders with Direct3D 12.
        if files.contains(where: { $0.relative.lowercased().hasSuffix("/d3d12/d3d12core.dll") }) {
            notes.append("hint: bundled D3D12 Agility SDK")
            return BackendDetection(api: .d3d12, notes: notes)
        }

        // The launch target plus the largest executables (a launcher stub often fronts the
        // real *-Shipping.exe), and the engine DLLs that do the rendering.
        var candidates: [URL] = []
        if let launchTarget, FileManager.default.fileExists(atPath: launchTarget.path(percentEncoded: false)) {
            candidates.append(launchTarget)
        }
        let ranked = files
            .filter { isCandidate($0.relative) && $0.size > 200 * 1024 }
            .filter { $0.relative.firstMatch(of: skippedDirs) == nil && $0.relative.firstMatch(of: agilityCore) == nil }
            .sorted { $0.size > $1.size }
            .prefix(12)
        for f in ranked where !candidates.contains(f.url) { candidates.append(f.url) }
        guard !candidates.isEmpty else { return BackendDetection(api: .none, notes: notes + ["no candidate binaries"]) }

        var found: [GraphicsRuntime: ImportKind] = [:]
        for url in candidates {
            let imports = (try? PEImports(contentsOf: url)) ?? PEImports()
            notes.append("pe-d3d: \(imports.flags) \(url.path(percentEncoded: false))")
            for (runtime, kind) in imports.runtimes where found[runtime] == nil || kind == .direct {
                found[runtime] = kind
            }
        }

        // Engines that load their renderer at run time (Unreal Engine 5 among them) import no
        // Direct3D DLL at all; the runtime names in the largest binary are the best remaining hint.
        if found.isEmpty, let biggest = largest(candidates), let data = try? Data(contentsOf: biggest, options: .mappedIfSafe) {
            for (needle, runtime) in [("d3d12.dll", GraphicsRuntime.d3d12), ("d3d11.dll", .d3d11), ("d3d9.dll", .d3d9)]
            where containsCaseInsensitive(data, needle) {
                found[runtime] = .delayed
                notes.append("hint: runtime names in \(biggest.lastPathComponent): \(runtime.rawValue):d")
                break
            }
        }

        return BackendDetection(api: classify(found), notes: notes)
    }

    static func classify(_ found: [GraphicsRuntime: ImportKind]) -> DetectedAPI {
        func has(_ r: GraphicsRuntime, _ k: ImportKind? = nil) -> Bool {
            guard let kind = found[r] else { return false }
            return k == nil || kind == k
        }
        if has(.d3d12, .direct) { return .d3d12 }
        if has(.d3d11, .direct) || has(.dxgi, .direct) || has(.d3d10, .direct) { return .d3d11 }
        if has(.d3d12, .delayed) { return .d3d12 }
        if has(.d3d11, .delayed) || has(.dxgi, .delayed) || has(.d3d10, .delayed) { return .d3d11 }
        if has(.d3d9) || has(.d3d8) || has(.ddraw) { return .d3d9 }
        if has(.opengl) { return .opengl }
        if has(.vulkan) { return .vulkan }
        return .none
    }

    struct GameFile { var url: URL; var relative: String; var size: Int }

    /// Regular files up to `maxDepth` levels below `root`; `relative` starts with "/".
    static func gameFiles(in root: URL) -> [GameFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        var out: [GameFile] = []
        for case let url as URL in walker {
            if walker.level > maxDepth { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            var relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(rootPath.count))
            if !relative.hasPrefix("/") { relative = "/" + relative }
            out.append(GameFile(url: url, relative: relative, size: values.fileSize ?? 0))
        }
        return out
    }

    static func isCandidate(_ relative: String) -> Bool {
        let name = (relative as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".exe") || name == "unityplayer.dll" { return true }
        guard name.hasSuffix(".dll") else { return false }
        return name.contains("render") || name.hasPrefix("cryrenderd3d")
            || name.contains("d3d11") || name.contains("d3d12")
    }

    static func largest(_ urls: [URL]) -> URL? {
        urls.max { size($0) < size($1) }
    }

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func containsCaseInsensitive(_ data: Data, _ needle: String) -> Bool {
        let lower = Array(needle.utf8)
        let upper = Array(needle.uppercased().utf8)
        let n = lower.count
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard buf.count >= n else { return false }
            outer: for i in 0...(buf.count - n) {
                for j in 0..<n where buf[i + j] != lower[j] && buf[i + j] != upper[j] { continue outer }
                return true
            }
            return false
        }
    }
}
