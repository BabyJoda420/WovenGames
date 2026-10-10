import Foundation
import XCTest
@testable import WovenCore

/// Builds a minimal PE32+ image with one section holding the given imports.
func makePE(imports: [String] = [], delayed: [String] = [], delayVA: Bool = false) -> Data {
    var d = Data(count: 0x400)
    func w16(_ off: Int, _ v: UInt16) { d[off] = UInt8(v & 0xff); d[off + 1] = UInt8(v >> 8) }
    func w32(_ off: Int, _ v: UInt32) { w16(off, UInt16(v & 0xffff)); w16(off + 2, UInt16(v >> 16)) }
    func str(_ off: Int, _ s: String) { for (i, b) in s.utf8.enumerated() { d[off + i] = b } }

    let sectionVA: UInt32 = 0x1000, sectionRaw = 0x200
    func rvaOff(_ rva: UInt32) -> Int { sectionRaw + Int(rva - sectionVA) }

    w16(0, 0x5a4d); w32(0x3c, 0x80)
    w32(0x80, 0x4550)
    let coff = 0x84, opt = coff + 20
    w16(coff, 0x8664); w16(coff + 2, 1); w16(coff + 16, 240)
    w16(opt, 0x20b)
    let imageBase: UInt64 = 0x1_4000_0000
    w32(opt + 24, UInt32(imageBase & 0xffff_ffff)); w32(opt + 28, UInt32(imageBase >> 32))
    let dirs = opt + 112
    let section = opt + 240
    w32(section + 8, 0x200); w32(section + 12, sectionVA); w32(section + 16, 0x200); w32(section + 20, UInt32(sectionRaw))

    var nameRVA: UInt32 = 0x1100
    if !imports.isEmpty {
        w32(dirs + 8, 0x1000)
        for (i, name) in imports.enumerated() {
            w32(rvaOff(0x1000) + i * 20 + 12, nameRVA); str(rvaOff(nameRVA), name); nameRVA += 0x20
        }
    }
    if !delayed.isEmpty {
        w32(dirs + 13 * 8, 0x1080)
        for (i, name) in delayed.enumerated() {
            let desc = rvaOff(0x1080) + i * 32
            w32(desc, delayVA ? 0 : 1)
            w32(desc + 4, delayVA ? UInt32(truncatingIfNeeded: UInt64(nameRVA) + imageBase) : nameRVA)
            str(rvaOff(nameRVA), name); nameRVA += 0x20
        }
    }
    return d
}

final class PEImportsTests: XCTestCase {
    func testDirectAndDelayedImports() {
        let pe = PEImports(data: makePE(imports: ["KERNEL32.dll", "d3d11.dll", "DXGI.dll"], delayed: ["d3d12.dll"]))
        XCTAssertTrue(pe.isPE)
        XCTAssertEqual(pe.runtimes, [.d3d11: .direct, .dxgi: .direct, .d3d12: .delayed])
        XCTAssertEqual(pe.flags, "d3d12:d,d3d11:i,dxgi:i")
    }

    func testDirectWinsOverDelayedAndAliases() {
        let pe = PEImports(data: makePE(imports: ["d3d10_1.dll", "OPENGL32.DLL"], delayed: ["d3d10core.dll", "vulkan-1.dll"]))
        XCTAssertEqual(pe.runtimes, [.d3d10: .direct, .opengl: .direct, .vulkan: .delayed])
    }

    func testOldStyleDelayDescriptorsHoldVAs() {
        let pe = PEImports(data: makePE(delayed: ["d3d9.dll"], delayVA: true))
        XCTAssertEqual(pe.runtimes, [.d3d9: .delayed])
    }

    func testNotAPE() {
        let pe = PEImports(data: Data(repeating: 0x41, count: 0x400))
        XCTAssertFalse(pe.isPE)
        XCTAssertEqual(pe.flags, "-")
    }
}

final class BackendDetectorTests: XCTestCase {
    func testClassifyPriority() {
        XCTAssertEqual(BackendDetector.classify([.d3d12: .direct, .d3d11: .direct]), .d3d12)
        XCTAssertEqual(BackendDetector.classify([.d3d12: .delayed, .dxgi: .direct]), .d3d11)
        XCTAssertEqual(BackendDetector.classify([.d3d12: .delayed]), .d3d12)
        XCTAssertEqual(BackendDetector.classify([.ddraw: .direct, .opengl: .direct]), .d3d9)
        XCTAssertEqual(BackendDetector.classify([.vulkan: .direct]), .vulkan)
        XCTAssertEqual(BackendDetector.classify([:]), .none)
        XCTAssertEqual(DetectedAPI.d3d12.backend, .d3dmetal)
        XCTAssertEqual(DetectedAPI.d3d11.backend, .dxmt)
        XCTAssertEqual(DetectedAPI.d3d9.backend, .wined3d)
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "woven-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// pads a PE past the 200 KB candidate threshold
    func big(_ pe: Data) -> Data { pe + Data(count: 300 * 1024) }

    func testAgilitySDKMeansD3D12() throws {
        let dir = try tempDir()
        try write(Data("x".utf8), dir.appending(path: "Game/Binaries/Win64/D3D12/D3D12Core.dll"))
        XCTAssertEqual(BackendDetector.detect(launchTarget: nil, installDir: dir).api, .d3d12)
    }

    func testShippingExeBehindLauncherStub() throws {
        let dir = try tempDir()
        let stub = dir.appending(path: "Launcher.exe")
        try write(makePE(imports: ["KERNEL32.dll"]), stub)
        try write(big(makePE(imports: ["d3d11.dll"])), dir.appending(path: "Game/Binaries/Win64/Game-Win64-Shipping.exe"))
        // redistributables are ignored even when they are large
        try write(big(makePE(imports: ["d3d12.dll"])), dir.appending(path: "_CommonRedist/DirectX/dxsetup.exe"))
        let detection = BackendDetector.detect(launchTarget: stub, installDir: dir)
        XCTAssertEqual(detection.api, .d3d11)
        XCTAssertEqual(detection.backend, .dxmt)
    }

    func testRuntimeNameFallbackForUE5() throws {
        let dir = try tempDir()
        var exe = big(makePE(imports: ["KERNEL32.dll"]))
        exe.append(contentsOf: Array("...D3D12.DLL...".utf8))
        try write(exe, dir.appending(path: "Game-Win64-Shipping.exe"))
        XCTAssertEqual(BackendDetector.detect(launchTarget: nil, installDir: dir).api, .d3d12)
    }
}

final class SteamStatusTests: XCTestCase {
    func testManifestVersion() {
        XCTAssertEqual(SteamStatus.manifestVersion("\"osx\"\n{\n\t\"version\"\t\t\"1788652215\"\n"), "1788652215")
        XCTAssertNil(SteamStatus.manifestVersion("nothing"))
    }

    func testPin() throws {
        let cfg = FileManager.default.temporaryDirectory.appending(path: "steam-\(UUID().uuidString).cfg")
        defer { try? FileManager.default.removeItem(at: cfg) }
        try "BootStrapperInhibitUpdateOnLaunch=enable\n".write(to: cfg, atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamStatus.pin(config: cfg), .onLaunchOnly)
        try "BootStrapperInhibitAll=Enable\r\n".write(to: cfg, atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamStatus.pin(config: cfg), .full)
        XCTAssertEqual(SteamStatus.pin(config: cfg.appending(path: "missing")), .none)
    }

    func testInjection() throws {
        let plist = FileManager.default.temporaryDirectory.appending(path: "Info-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: plist) }
        func write(_ insert: String?) throws {
            var env: [String: Any] = ["LC_ALL": "en_US.UTF-8"]
            env["DYLD_INSERT_LIBRARIES"] = insert
            let data = try PropertyListSerialization.data(fromPropertyList: ["LSEnvironment": env], format: .xml, options: 0)
            try data.write(to: plist)
        }
        try write(nil)
        XCTAssertEqual(SteamStatus.injection(infoPlist: plist), SteamStatus.Injection.none)
        try write("/Applications/Steam.app/Contents/MacOS/notproton.dylib")
        XCTAssertEqual(SteamStatus.injection(infoPlist: plist), .notProton)
        try write("/x/wovengames.dylib")
        XCTAssertEqual(SteamStatus.injection(infoPlist: plist), .wovenGames)
    }
}

final class WineLaunchTests: XCTestCase {
    func runner() throws -> Runner {
        let root = FileManager.default.temporaryDirectory.appending(path: "runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try #"{"id":"test","kind":"selfbuilt","arch":"x86_64"}"#.write(to: root.appending(path: "runner.json"), atomically: true, encoding: .utf8)
        return try Runner(root: root)
    }

    func testBackendEnvironment() throws {
        let r = try runner()
        let root = r.root.path(percentEncoded: false)
        let base = ["PATH": "/usr/bin", "WINEDLLOVERRIDES": "leaked", "HOME": "/Users/x"]

        var launch = WineLaunch(runner: r, prefix: URL(filePath: "/tmp/pfx"), backend: .d3dmetal)
        var env = launch.environment(base: base)
        XCTAssertEqual(env["WINEDLLPATH_PREPEND"], "\(root)/lib/renderers/d3dmetal")
        XCTAssertEqual(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"], "\(root)/lib/external/libd3dshared.dylib")
        XCTAssertEqual(env["WINEPREFIX"], "/tmp/pfx")
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertNil(env["WINEDLLOVERRIDES"])
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["PATH"], "\(root)/bin:/usr/bin")

        launch.backend = .wined3d
        launch.msync = false
        env = launch.environment(base: base)
        XCTAssertNil(env["WINEDLLPATH_PREPEND"])
        XCTAssertNil(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"])
        XCTAssertEqual(env["WINEMSYNC"], "0")
    }

    func testPrefixNames() throws {
        let prefixes = Prefixes(paths: Paths(home: URL(filePath: "/Users/x")))
        XCTAssertNoThrow(try prefixes.url("clair-obscur_1903340"))
        XCTAssertThrowsError(try prefixes.url("../evil"))
        XCTAssertThrowsError(try prefixes.url(".."))
        XCTAssertThrowsError(try prefixes.url(""))
    }
}

final class SteamPatcherTests: XCTestCase {
    var home: URL!
    var app: URL!
    var patcher: SteamPatcher!

    override func setUpWithError() throws {
        let fm = FileManager.default
        home = fm.temporaryDirectory.appending(path: "woven-home-\(UUID().uuidString)")
        app = home.appending(path: "Applications/Steam.app")
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        // a real Mach-O for steam_osx and for the hook, so codesign has something to sign
        let src = home.appending(path: "x.c")
        try "int x(void){return 0;}\nint main(void){return 0;}\n".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertEqual(Shell.capture("/usr/bin/clang", ["-o", app.appending(path: "Contents/MacOS/steam_osx").path(percentEncoded: false), src.path(percentEncoded: false)]).status, 0)
        let support = home.appending(path: "Library/Application Support/WovenGames")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        XCTAssertEqual(Shell.capture("/usr/bin/clang", ["-dynamiclib", "-o", support.appending(path: "wovengames.dylib").path(percentEncoded: false), src.path(percentEncoded: false)]).status, 0)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleExecutable": "steam_osx",
                                    "LSEnvironment": ["LC_ALL": "en_US.UTF-8"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        patcher = SteamPatcher(paths: Paths(home: home, steamApp: app))
        patcher.manageSteamProcess = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func env() throws -> [String: Any] {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        return plist["LSEnvironment"] as? [String: Any] ?? [:]
    }

    func testPatchAndUnpatchRoundTrip() throws {
        try patcher.patch()
        XCTAssertEqual(try env()["DYLD_INSERT_LIBRARIES"] as? String, patcher.deployedDylib.path(percentEncoded: false))
        XCTAssertEqual(try env()["LC_ALL"] as? String, "en_US.UTF-8")
        XCTAssertTrue(FileManager.default.fileExists(atPath: patcher.deployedDylib.path(percentEncoded: false)))
        XCTAssertEqual(SteamStatus(paths: Paths(home: home, steamApp: app).steam).injection, .wovenGames)
        // patching twice is fine and keeps the first (pristine) backup
        try patcher.patch()

        try patcher.unpatch()
        XCTAssertNil(try env()["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(try env()["LC_ALL"] as? String, "en_US.UTF-8")
        XCTAssertFalse(FileManager.default.fileExists(atPath: patcher.deployedDylib.path(percentEncoded: false)))
    }

    func testTakesOverNotProtonAndUsesItsBackup() throws {
        let fm = FileManager.default
        let plistURL = app.appending(path: "Contents/Info.plist")
        // NotProton's pristine backup, then NotProton's patched plist and dylib
        let npBackups = home.appending(path: "Library/Application Support/notproton/backups")
        try fm.createDirectory(at: npBackups, withIntermediateDirectories: true)
        try fm.copyItem(at: plistURL, to: npBackups.appending(path: "Info.plist.before-notproton"))
        let np = app.appending(path: "Contents/MacOS/notproton.dylib")
        try fm.copyItem(at: home.appending(path: "Library/Application Support/WovenGames/wovengames.dylib"), to: np)
        let patched: [String: Any] = ["CFBundleExecutable": "steam_osx",
                                      "LSEnvironment": ["LC_ALL": "en_US.UTF-8", "DYLD_INSERT_LIBRARIES": np.path(percentEncoded: false)]]
        try PropertyListSerialization.data(fromPropertyList: patched, format: .xml, options: 0).write(to: plistURL)

        try patcher.patch()
        XCTAssertFalse(fm.fileExists(atPath: np.path(percentEncoded: false)))
        XCTAssertEqual(try env()["DYLD_INSERT_LIBRARIES"] as? String, patcher.deployedDylib.path(percentEncoded: false))
        try patcher.unpatch()
        // restored to the pre-NotProton plist, bundle id included
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
        XCTAssertEqual(restored["CFBundleIdentifier"] as? String, "com.valvesoftware.steam")
        XCTAssertNil(try env()["DYLD_INSERT_LIBRARIES"])
    }

    func testRefusesForeignInsert() throws {
        let plistURL = app.appending(path: "Contents/Info.plist")
        let foreign: [String: Any] = ["LSEnvironment": ["DYLD_INSERT_LIBRARIES": "/opt/other.dylib"]]
        try PropertyListSerialization.data(fromPropertyList: foreign, format: .xml, options: 0).write(to: plistURL)
        XCTAssertThrowsError(try patcher.patch())
    }

    func testPinKeepsOtherLines() throws {
        let cfg = home.appending(path: "Library/Application Support/Steam/steam.cfg")
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Foo=1\nBootStrapperInhibitAll=enable\n".write(to: cfg, atomically: true, encoding: .utf8)
        try patcher.pin()
        XCTAssertEqual(try String(contentsOf: cfg, encoding: .utf8), "Foo=1\nBootStrapperInhibitAll=enable\nBootStrapperInhibitUpdateOnLaunch=enable\n")
        try patcher.pin()
        try patcher.unpin()
        XCTAssertEqual(try String(contentsOf: cfg, encoding: .utf8), "Foo=1\n")
    }
}
