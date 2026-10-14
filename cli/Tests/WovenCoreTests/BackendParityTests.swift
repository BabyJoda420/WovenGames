import Foundation
import XCTest
@testable import WovenCore

/// The compat tool's run script (detect_d3d with the pe-d3d helper) and BackendDetector must
/// pick the same API for the same game folder: the app shows what the Swift side predicts, the
/// run script decides what actually runs. Each case builds a folder and runs both.
final class BackendParityTests: XCTestCase {
    static let repo = URL(filePath: #filePath).appending(path: "../../../..").standardizedFileURL
    static var work: URL?
    static var peD3D: URL?
    static var detectScript: URL?

    override class func setUp() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "woven-parity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        work = dir

        let tool = dir.appending(path: "pe-d3d")
        let source = repo.appending(path: "notproton/helpers/pe-d3d.c")
        if run("/usr/bin/cc", ["-O1", "-o", tool.path(percentEncoded: false), source.path(percentEncoded: false)]).status == 0 {
            peD3D = tool
        }

        // the function exactly as the run script defines it
        let runScript = repo.appending(path: "notproton/dylib/feats/compat_run.sh")
        let function = run("/usr/bin/awk", ["/^detect_d3d\\(\\) \\{/,/^\\}/", runScript.path(percentEncoded: false)]).output
        if function.contains("detect_d3d()") {
            let script = dir.appending(path: "detect.sh")
            try? function.write(to: script, atomically: true, encoding: .utf8)
            detectScript = script
        }
    }

    override class func tearDown() {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    static func run(_ tool: String, _ args: [String], env: [String: String]? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// detect_d3d's answer for a folder, run by /bin/sh like Steam runs the script.
    func shellDetect(installDir: URL, target: URL?) throws -> String {
        // a skip would count as a pass in CI, so a missing piece fails
        guard let peD3D = Self.peD3D else {
            XCTFail("could not build notproton/helpers/pe-d3d.c with /usr/bin/cc")
            return ""
        }
        guard let script = Self.detectScript else {
            XCTFail("detect_d3d() not found in compat_run.sh")
            return ""
        }
        let body = #". "$DETECT"; detect_d3d "$TARGET""#
        let env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DETECT": script.path(percentEncoded: false),
            "TARGET": target?.path(percentEncoded: false) ?? "",
            "STEAM_COMPAT_INSTALL_PATH": installDir.path(percentEncoded: false),
            "pe_d3d": peD3D.path(percentEncoded: false),
            "log": "/dev/null",
        ]
        let result = Self.run("/bin/sh", ["-c", body], env: env)
        XCTAssertEqual(result.status, 0)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: fixtures

    struct Case {
        var name: String
        var expected: DetectedAPI
        var target: String?
        var files: [(String, Data)]
    }

    static func big(_ pe: Data, kb: Int = 300) -> Data { pe + Data(count: kb * 1024) }

    static func padded(_ pe: Data, to bytes: Int) -> Data { pe + Data(count: bytes - pe.count) }

    static var cases: [Case] {
        let none = makePE(imports: ["KERNEL32.dll"])
        var ue5 = big(none)
        ue5.append(contentsOf: Array("...D3D12.DLL...".utf8))
        var ue4 = big(none)
        ue4.append(contentsOf: Array("..d3d11.dll..".utf8))
        var old = big(none)
        old.append(contentsOf: Array("..d3d9.dll..".utf8))
        // 13 plain executables; only the smallest, which falls outside the top 12, links D3D11
        let crowd = (0..<13).map { i in
            ("Bin/Tool\(i).exe", big(makePE(imports: i == 12 ? ["d3d11.dll"] : ["KERNEL32.dll"]), kb: 400 - i))
        }
        return [
            Case(name: "agility sdk", expected: .d3d12, files: [
                ("Game/Binaries/Win64/D3D12/D3D12Core.dll", Data("x".utf8)),
                ("Game/Binaries/Win64/Game.exe", big(makePE(imports: ["d3d11.dll"]))),
            ]),
            Case(name: "unity at the top", expected: .d3d11, target: "Game.exe", files: [
                ("UnityPlayer.dll", big(makePE(imports: ["OPENGL32.dll"]))),
                ("Game.exe", none),
            ]),
            Case(name: "unity one folder down", expected: .d3d11, files: [
                ("Sub/UnityPlayer.dll", big(makePE(imports: ["OPENGL32.dll"]))),
            ]),
            Case(name: "unity too deep to count as unity", expected: .opengl, files: [
                ("A/B/UnityPlayer.dll", big(makePE(imports: ["OPENGL32.dll"]))),
            ]),
            Case(name: "launcher stub, shipping exe and a redist", expected: .d3d11, target: "Launcher.exe", files: [
                ("Launcher.exe", none),
                ("Game/Binaries/Win64/Game-Win64-Shipping.exe", big(makePE(imports: ["d3d11.dll"]))),
                ("_CommonRedist/DirectX/dxsetup.exe", big(makePE(imports: ["d3d12.dll"]))),
                ("EasyAntiCheat/eac.exe", big(makePE(imports: ["d3d12.dll"]))),
            ]),
            Case(name: "ue5 runtime names", expected: .d3d12, files: [("Game-Win64-Shipping.exe", ue5)]),
            Case(name: "ue4 runtime names", expected: .d3d11, files: [("Game-Win64-Shipping.exe", ue4)]),
            Case(name: "direct dxgi beats delayed d3d12", expected: .d3d11, files: [
                ("Game.exe", big(makePE(imports: ["DXGI.dll"], delayed: ["d3d12.dll"]))),
            ]),
            Case(name: "delayed d3d12 with old-style VAs", expected: .d3d12, files: [
                ("Game.exe", big(makePE(delayed: ["d3d12.dll"], delayVA: true))),
            ]),
            Case(name: "d3d9 runtime name", expected: .d3d9, files: [("Game.exe", old)]),
            Case(name: "d3d10_1 counts as d3d11", expected: .d3d11, files: [
                ("Game.exe", big(makePE(imports: ["d3d10_1.dll"]))),
            ]),
            Case(name: "delayed d3d10core", expected: .d3d11, files: [
                ("Game.exe", big(makePE(delayed: ["d3d10core.dll"]))),
            ]),
            Case(name: "d3d8", expected: .d3d9, files: [("Game.exe", big(makePE(imports: ["D3D8.dll"])))]),
            Case(name: "spaces in names", expected: .d3d11, target: "Game Folder/Game Launcher.exe", files: [
                ("Game Folder/Game Launcher.exe", none),
                ("Game Folder/Binaries/My Game-Shipping.exe", big(makePE(imports: ["d3d11.dll"]))),
                ("Game Folder/Binaries/Crash Reporter.exe", big(makePE(imports: ["KERNEL32.dll"]), kb: 200)),
            ]),
            Case(name: "d3d9", expected: .d3d9, files: [("Game.exe", big(makePE(imports: ["d3d9.dll"])))]),
            Case(name: "ddraw beats opengl", expected: .d3d9, files: [
                ("Game.exe", big(makePE(imports: ["DDRAW.dll", "OPENGL32.dll"]))),
            ]),
            Case(name: "vulkan", expected: .vulkan, files: [("Game.exe", big(makePE(imports: ["vulkan-1.dll"])))]),
            Case(name: "renderer dll", expected: .d3d11, files: [
                ("Game.exe", big(none)),
                ("Engine/RenderD3D11.dll", big(makePE(imports: ["d3d11.dll"]))),
            ]),
            Case(name: "small target still counts", expected: .d3d11, target: "Game.exe", files: [
                ("Game.exe", makePE(imports: ["d3d11.dll"])),
            ]),
            Case(name: "small files only", expected: .none, files: [("Game.exe", makePE(imports: ["d3d11.dll"]))]),
            Case(name: "just over 200 KB", expected: .d3d11, files: [
                ("Game.exe", padded(makePE(imports: ["d3d11.dll"]), to: 200 * 1024 + 1)),
            ]),
            Case(name: "exactly 200 KB", expected: .none, files: [
                ("Game.exe", padded(makePE(imports: ["d3d11.dll"]), to: 200 * 1024)),
            ]),
            Case(name: "upper-case name at depth 6", expected: .d3d11, files: [
                ("a/b/c/d/e/GAME.EXE", big(makePE(imports: ["d3d11.dll"]))),
            ]),
            Case(name: "depth 7 is not searched", expected: .none, files: [
                ("a/b/c/d/e/f/Game.exe", big(makePE(imports: ["d3d11.dll"]))),
            ]),
            Case(name: "only the largest 12 binaries", expected: .none, files: crowd),
        ]
    }

    func testShellAndSwiftAgree() throws {
        for c in Self.cases {
            let dir = Self.work!.appending(path: c.name)
            for (path, data) in c.files {
                let url = dir.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            let target = c.target.map { dir.appending(path: $0) }
            let swift = BackendDetector.detect(launchTarget: target, installDir: dir).api
            let shell = try shellDetect(installDir: dir, target: target)
            XCTAssertEqual(swift, c.expected, "Swift, \(c.name)")
            XCTAssertEqual(shell, c.expected.rawValue, "run script, \(c.name)")
        }
    }
}
