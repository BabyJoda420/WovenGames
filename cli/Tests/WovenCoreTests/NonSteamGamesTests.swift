import Foundation
import XCTest
@testable import WovenCore

final class NonSteamGamesTests: XCTestCase {
    var home: URL!
    var paths: Paths!
    var nonSteam: NonSteamGames!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "woven-nonsteam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = Paths(home: home)
        nonSteam = NonSteamGames(paths: paths)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func createDummyExe(named: String, in subfolder: String = "Games") throws -> URL {
        let dir = home.appending(path: subfolder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appending(path: named)
        try "dummy MZ executable".write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    func testAddValidExe() throws {
        let exe = try createDummyExe(named: "Hades.exe")
        let game = try nonSteam.add(exe: exe)

        XCTAssertEqual(game.id, "9000000001")
        XCTAssertEqual(game.name, "Hades")
        XCTAssertEqual(game.exe, exe.standardizedFileURL.path(percentEncoded: false))
        XCTAssertEqual(game.args, [])

        let list = nonSteam.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first, game)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonSteam.file.path(percentEncoded: false)))
    }

    func testAddCustomNameAndArgs() throws {
        let exe = try createDummyExe(named: "runner.EXE")
        let game = try nonSteam.add(exe: exe, name: "Custom Runner", args: ["-dx11", "-console"])

        XCTAssertEqual(game.id, "9000000001")
        XCTAssertEqual(game.name, "Custom Runner")
        XCTAssertEqual(game.args, ["-dx11", "-console"])
    }

    func testAddRejectsNonExe() throws {
        let txt = home.appending(path: "game.txt")
        try "not an exe".write(to: txt, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try nonSteam.add(exe: txt)) { error in
            guard case NonSteamError.notAnExe(let url) = error else {
                XCTFail("expected notAnExe, got \(error)")
                return
            }
            XCTAssertEqual(url.lastPathComponent, "game.txt")
        }
    }

    func testAddRejectsNonExistent() throws {
        let missing = home.appending(path: "missing.exe")
        XCTAssertThrowsError(try nonSteam.add(exe: missing)) { error in
            guard case NonSteamError.fileNotFound(let url) = error else {
                XCTFail("expected fileNotFound, got \(error)")
                return
            }
            XCTAssertEqual(url.lastPathComponent, "missing.exe")
        }
    }

    func testIDsNeverReused() throws {
        let exe1 = try createDummyExe(named: "g1.exe")
        let exe2 = try createDummyExe(named: "g2.exe")
        let exe3 = try createDummyExe(named: "g3.exe")

        let g1 = try nonSteam.add(exe: exe1)
        let g2 = try nonSteam.add(exe: exe2)
        XCTAssertEqual(g1.id, "9000000001")
        XCTAssertEqual(g2.id, "9000000002")

        try nonSteam.remove(id: g1.id)
        XCTAssertEqual(nonSteam.list().map(\.id), ["9000000002"])

        // Next game must receive 9000000003, not reusing 9000000001
        let g3 = try nonSteam.add(exe: exe3)
        XCTAssertEqual(g3.id, "9000000003")
    }

    func testRemoveUnknownThrows() throws {
        XCTAssertThrowsError(try nonSteam.remove(id: "9000000099")) { error in
            guard case NonSteamError.unknown(let id) = error else {
                XCTFail("expected unknown id error, got \(error)")
                return
            }
            XCTAssertEqual(id, "9000000099")
        }
    }

    func testRemoveWithDeleteData() throws {
        let exe = try createDummyExe(named: "DataGame.exe")
        let game = try nonSteam.add(exe: exe)

        let compat = nonSteam.compatData(id: game.id)
        let dummyPfx = compat.appending(path: "pfx/system.reg")
        try FileManager.default.createDirectory(at: dummyPfx.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "reg data".write(to: dummyPfx, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compat.path(percentEncoded: false)))

        // 1. Remove without deleteData (keeps folder)
        let exe2 = try createDummyExe(named: "DataGame2.exe")
        let game2 = try nonSteam.add(exe: exe2)
        let compat2 = nonSteam.compatData(id: game2.id)
        try FileManager.default.createDirectory(at: compat2, withIntermediateDirectories: true)

        try nonSteam.remove(id: game2.id, deleteData: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compat2.path(percentEncoded: false)), "data preserved without flag")

        // 2. Remove with deleteData (removes folder)
        try nonSteam.remove(id: game.id, deleteData: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: compat.path(percentEncoded: false)), "data removed with flag")
    }

    func testListSortedByName() throws {
        let z = try createDummyExe(named: "Zelda.exe")
        let a = try createDummyExe(named: "Apex.exe")
        let m = try createDummyExe(named: "minecraft.exe")

        try nonSteam.add(exe: z)
        try nonSteam.add(exe: a)
        try nonSteam.add(exe: m, name: "Minecraft")

        let names = nonSteam.list().map(\.name)
        XCTAssertEqual(names, ["Apex", "Minecraft", "Zelda"])
    }

    func testInstalledGames() throws {
        let exe = try createDummyExe(named: "Portal.exe", in: "SteamApps/common/Portal")
        let game = try nonSteam.add(exe: exe, name: "Portal GOG")

        let installed = nonSteam.installedGames()
        XCTAssertEqual(installed.count, 1)

        let g = installed.first!
        XCTAssertEqual(g.appID, game.id)
        XCTAssertEqual(g.name, "Portal GOG")
        XCTAssertEqual(g.installDir.path(percentEncoded: false), exe.deletingLastPathComponent().path(percentEncoded: false))
        XCTAssertEqual(g.compatData.path(percentEncoded: false), nonSteam.compatData(id: game.id).path(percentEncoded: false))
        XCTAssertEqual(g.sizeOnDisk, 0)
        XCTAssertEqual(g.prefix.path(percentEncoded: false), nonSteam.compatData(id: game.id).appending(path: "pfx").path(percentEncoded: false))
    }

    func testIsNonSteam() {
        XCTAssertTrue(NonSteamGames.isNonSteam(appID: "9000000001"))
        XCTAssertTrue(NonSteamGames.isNonSteam(appID: "9999999999"))
        XCTAssertFalse(NonSteamGames.isNonSteam(appID: "440"))
        XCTAssertFalse(NonSteamGames.isNonSteam(appID: "1234567890"))
        XCTAssertFalse(NonSteamGames.isNonSteam(appID: "8000000001"))
        XCTAssertFalse(NonSteamGames.isNonSteam(appID: "900000001"))      // 9 digits
        XCTAssertFalse(NonSteamGames.isNonSteam(appID: "90000000001"))    // 11 digits
        XCTAssertFalse(NonSteamGames.isNonSteam(appID: "900000000a"))    // non-numeric
        XCTAssertFalse(NonSteamGames.isNonSteam(appID: ""))
    }

    func testDamagedLibraryIsNotOverwritten() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "woven-ns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let library = NonSteamGames(paths: Paths(home: home, steamApp: home.appending(path: "Steam.app")))
        try FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        try "{ not json".write(to: library.file, atomically: true, encoding: .utf8)
        let exe = home.appending(path: "Game.exe")
        try Data("MZ".utf8).write(to: exe)
        XCTAssertThrowsError(try library.add(exe: exe))
        XCTAssertEqual(try String(contentsOf: library.file, encoding: .utf8), "{ not json", "left as it was")
        XCTAssertEqual(library.list(), [])
    }

    func testLaunchCommandIsWhatSteamWouldPass() throws {
        let home = URL(filePath: "/Users/x")
        let paths = Paths(home: home)
        let game = NonSteamGame(id: "9000000007", name: "Game", exe: "/Games/My Game/Game.exe", args: ["-windowed"])
        let (args, env) = NonSteamLaunch(game: game, paths: paths).command(base: ["HOME": "/Users/x", "WINEDEBUG": "+all"])
        XCTAssertEqual(args, ["waitforexitandrun", "/Games/My Game/Game.exe", "-windowed"])
        XCTAssertEqual(env["WOVEN_NO_STEAM"], "1")
        XCTAssertEqual(env["STEAM_COMPAT_APP_ID"], "9000000007")
        XCTAssertEqual(env["STEAM_COMPAT_INSTALL_PATH"], "/Games/My Game")
        XCTAssertEqual(env["STEAM_COMPAT_DATA_PATH"], "/Users/x/Library/Application Support/WovenGames/nonsteam/9000000007")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }
}
