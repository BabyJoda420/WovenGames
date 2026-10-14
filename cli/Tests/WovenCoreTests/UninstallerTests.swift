import Foundation
import XCTest
@testable import WovenCore

final class UninstallerTests: XCTestCase {
    var home: URL!
    var app: URL!
    var paths: Paths!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "woven-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        home = dir
        app = home.appending(path: "Applications/Steam.app")
        paths = Paths(home: home, steamApp: app)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func put(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func putPlist(_ dict: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }

    func testPlanEmptyEnvironment() throws {
        let uninstaller = Uninstaller(paths: paths, deletePrefixes: false, manageSteamProcess: false)
        let plan = uninstaller.plan()

        XCTAssertFalse(plan.isBlockedByRunningGames)
        XCTAssertEqual(plan.runningGames, [])
        XCTAssertFalse(plan.unpatchSteam)
        XCTAssertFalse(plan.unpinSteam)
        XCTAssertFalse(plan.removeCompatTool)
        XCTAssertEqual(plan.prefixesToDelete, [])
        XCTAssertFalse(plan.removeSupport)
        XCTAssertNil(plan.developerTree)
        XCTAssertNil(plan.developerTreeSize)
        XCTAssertTrue(plan.descriptions.isEmpty)
    }

    func testRunningGameBlocksUninstall() throws {
        // Spawn a process named compat_run so GameSessions recognizes it as a running game
        let script = home.appending(path: "compat_run")
        try put("sleep 30\nexit 0\n", script)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false)]
        try process.run()
        addTeardownBlock {
            _ = Shell.capture("/usr/bin/pkill", ["-P", "\(process.processIdentifier)"])
            process.terminate()
            process.waitUntilExit()
        }

        let pid = process.processIdentifier
        let launchers = paths.support.appending(path: "launchers/550")
        try put("\(pid)\n", launchers.appending(path: "run.pid"))

        let uninstaller = Uninstaller(paths: paths, deletePrefixes: false, manageSteamProcess: false)
        let plan = uninstaller.plan()

        XCTAssertTrue(plan.isBlockedByRunningGames)
        XCTAssertEqual(plan.runningGames, ["550"])

        XCTAssertThrowsError(try uninstaller.run(plan: plan)) { error in
            guard case UninstallerError.gameRunning(let ids) = error else {
                XCTFail("expected gameRunning error, got \(error)")
                return
            }
            XCTAssertEqual(ids, ["550"])
        }
    }

    func testPlanAndRunUninstallsCleanly() throws {
        let fm = FileManager.default

        // 1. A Steam.app patched by the real patcher (as in SteamPatcherTests): real Mach-Os
        //    for steam_osx and the hook, so codesign has something to sign
        let src = home.appending(path: "x.c")
        try put("int x(void){return 0;}\nint main(void){return 0;}\n", src)
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        XCTAssertEqual(Shell.capture("/usr/bin/clang", ["-o", app.appending(path: "Contents/MacOS/steam_osx").path(percentEncoded: false), src.path(percentEncoded: false)]).status, 0)
        try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
        XCTAssertEqual(Shell.capture("/usr/bin/clang", ["-dynamiclib", "-o", paths.support.appending(path: "wovengames.dylib").path(percentEncoded: false), src.path(percentEncoded: false)]).status, 0)
        try putPlist(["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleExecutable": "steam_osx",
                      "LSEnvironment": ["LC_ALL": "en_US.UTF-8"]], paths.steam.infoPlist)
        var patcher = SteamPatcher(paths: paths)
        patcher.manageSteamProcess = false
        try patcher.patch()
        XCTAssertEqual(SteamStatus(paths: paths.steam).injection, .wovenGames)

        // 3. Pinned steam.cfg
        try put("BootStrapperInhibitUpdateOnLaunch=enable\n", paths.steam.configFile)

        // 4. Compat tool folder (patch() may already have made it)
        let compatTool = paths.steam.compatTools.appending(path: "wovengames-proton")
        if !fm.fileExists(atPath: compatTool.path(percentEncoded: false)) {
            try put("echo run\n", compatTool.appending(path: "run"))
        }

        // 5. Support files
        try put("engine 0.2.1\n", paths.support.appending(path: "engine.version"))
        try put("log\n", paths.support.appending(path: "wovengames.log"))

        let uninstaller = Uninstaller(paths: paths, deletePrefixes: false, manageSteamProcess: false)
        let plan = uninstaller.plan()

        XCTAssertFalse(plan.isBlockedByRunningGames)
        XCTAssertTrue(plan.unpatchSteam)
        XCTAssertTrue(plan.unpinSteam)
        XCTAssertTrue(plan.removeCompatTool)
        XCTAssertTrue(plan.removeSupport)
        XCTAssertEqual(plan.descriptions.count, 4)

        // Execute uninstall
        var logs: [String] = []
        try uninstaller.run(plan: plan) { logs.append($0) }

        // Assert Steam restored
        let restoredData = try Data(contentsOf: paths.steam.infoPlist)
        let restoredPlist = try PropertyListSerialization.propertyList(from: restoredData, format: nil) as! [String: Any]
        let env = restoredPlist["LSEnvironment"] as? [String: Any] ?? [:]
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"], "DYLD_INSERT_LIBRARIES must be removed")
        XCTAssertEqual(env["LC_ALL"] as? String, "en_US.UTF-8")

        // Assert unpinned
        let cfgText = try? String(contentsOf: paths.steam.configFile, encoding: .utf8)
        XCTAssertFalse(cfgText?.contains("BootStrapperInhibitUpdateOnLaunch") ?? false)

        // Assert compat tool removed
        XCTAssertFalse(fm.fileExists(atPath: compatTool.path(percentEncoded: false)))

        // Assert support folder removed
        XCTAssertFalse(fm.fileExists(atPath: paths.support.path(percentEncoded: false)))
    }

    func testPrefixesKeptByDefaultAndDeletedWithFlag() throws {
        let fm = FileManager.default

        // Create default library with two games (one WovenGames, one other)
        let main = paths.steam.userData
        let ext = home.appending(path: "Volumes/Ext/SteamLibrary")

        let vdf = """
        "libraryfolders"
        {
        \t"0" { "path" "\(main.path(percentEncoded: false))" }
        \t"1" { "path" "\(ext.path(percentEncoded: false))" }
        }
        """
        try put(vdf, main.appending(path: "steamapps/libraryfolders.vdf"))

        // Game 100: has wovengames-run.log (WovenGames game)
        let g100 = main.appending(path: "steamapps/compatdata/100")
        try put("run log\n", g100.appending(path: "wovengames-run.log"))
        try put("pfx\n", g100.appending(path: "pfx/system.reg"))

        // Game 200: external library, has wovengames-run.log
        let g200 = ext.appending(path: "steamapps/compatdata/200")
        try put("run log\n", g200.appending(path: "wovengames-run.log"))

        // Game 300: no wovengames-run.log (e.g. Proton save)
        let g300 = main.appending(path: "steamapps/compatdata/300")
        try put("proton save\n", g300.appending(path: "pfx/system.reg"))

        // 1. Default (keep prefixes)
        let keeper = Uninstaller(paths: paths, deletePrefixes: false, manageSteamProcess: false)
        let keepPlan = keeper.plan()
        XCTAssertEqual(keepPlan.prefixesToDelete, [])

        try keeper.run(plan: keepPlan)
        XCTAssertTrue(fm.fileExists(atPath: g100.path(percentEncoded: false)), "100 preserved by default")
        XCTAssertTrue(fm.fileExists(atPath: g200.path(percentEncoded: false)), "200 preserved by default")
        XCTAssertTrue(fm.fileExists(atPath: g300.path(percentEncoded: false)), "300 preserved by default")

        // 2. With deletePrefixes: true
        let deleter = Uninstaller(paths: paths, deletePrefixes: true, manageSteamProcess: false)
        let deletePlan = deleter.plan()
        // compare without a trailing slash: a URL to a folder that exists can carry one
        func key(_ url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") }
        let toDeletePaths = deletePlan.prefixesToDelete.map(key)
        XCTAssertTrue(toDeletePaths.contains(key(g100)))
        XCTAssertTrue(toDeletePaths.contains(key(g200)))
        XCTAssertFalse(toDeletePaths.contains(key(g300)), "non-WovenGames prefix not targeted")

        try deleter.run(plan: deletePlan)
        XCTAssertFalse(fm.fileExists(atPath: g100.path(percentEncoded: false)), "100 removed")
        XCTAssertFalse(fm.fileExists(atPath: g200.path(percentEncoded: false)), "200 removed")
        XCTAssertTrue(fm.fileExists(atPath: g300.path(percentEncoded: false)), "300 preserved even with flag")
    }

    func testDeveloperTreePreservedAndReported() throws {
        let devTree = home.appending(path: "Library/Developer/WovenGames/engine")
        try put("build artifacts\n", devTree.appending(path: "build.log"))

        let uninstaller = Uninstaller(paths: paths, deletePrefixes: false, manageSteamProcess: false)
        let plan = uninstaller.plan()

        XCTAssertNotNil(plan.developerTree)
        XCTAssertTrue((plan.developerTreeSize ?? 0) > 0)

        var logOutput = ""
        try uninstaller.run(plan: plan) { logOutput += $0 + "\n" }

        XCTAssertTrue(FileManager.default.fileExists(atPath: devTree.path(percentEncoded: false)), "developer tree untouched")
        XCTAssertTrue(logOutput.contains("engine build tree left intact"))
    }
}
