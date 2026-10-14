import Foundation
import XCTest
@testable import WovenCore

final class PrefixSnapshotsTests: XCTestCase {
    var home: URL!
    var compat: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "woven-snap-\(UUID().uuidString)")
        compat = home.appending(path: "Library/Application Support/Steam/steamapps/compatdata/123")
        try put("save 1", compat.appending(path: "pfx/drive_c/users/steamuser/save.dat"))
        try FileManager.default.createDirectory(at: compat.appending(path: "pfx/dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: compat.appending(path: "pfx/dosdevices/c:").path(percentEncoded: false),
                                                   withDestinationPath: "../drive_c")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func put(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    var save: URL { compat.appending(path: "pfx/drive_c/users/steamuser/save.dat") }

    func testTakeAndRestore() throws {
        let snapshots = PrefixSnapshots(compatData: compat)
        let taken = try snapshots.take(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(taken.id, "19700101-000000-manual")
        // the dosdevices link stays a link
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: taken.prefix.appending(path: "dosdevices/c:").path(percentEncoded: false)), "../drive_c")

        try put("save 2", save)
        XCTAssertEqual(read(taken.prefix.appending(path: "drive_c/users/steamuser/save.dat")), "save 1", "the snapshot does not follow later changes")

        var discarded: [URL] = []
        try snapshots.restore(taken.id) { discarded.append($0); try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(discarded.map(\.lastPathComponent), ["pfx"])
        XCTAssertEqual(read(save), "save 1")
        // the snapshot is still there for another restore
        XCTAssertEqual(snapshots.list().map(\.id), [taken.id])
    }

    func testSameSecondAndUnknownIDs() throws {
        let snapshots = PrefixSnapshots(compatData: compat)
        let t = Date(timeIntervalSince1970: 0)
        let a = try snapshots.take(now: t)
        let b = try snapshots.take(now: t)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertThrowsError(try snapshots.restore("nope") { _ in })
        XCTAssertThrowsError(try snapshots.delete("nope"))
        try snapshots.delete(a.id)
        XCTAssertEqual(snapshots.list().map(\.id), [b.id])
    }

    func testOnlyNewestAutomaticSnapshotsAreKept() throws {
        let snapshots = PrefixSnapshots(compatData: compat)
        let manual = try snapshots.take(now: Date(timeIntervalSince1970: 0))
        for i in 1...5 {
            try snapshots.take(reason: PrefixSnapshots.engineUpdate, allowCopy: false, now: Date(timeIntervalSince1970: TimeInterval(i * 60)))
        }
        let left = snapshots.list()
        XCTAssertEqual(left.filter(\.automatic).count, PrefixSnapshots.keepAutomatic)
        XCTAssertEqual(left.filter(\.automatic).map(\.id).first, "19700101-000500-engine-update", "newest kept")
        XCTAssertTrue(left.contains(manual), "manual snapshots stay")
    }

    func testBeforeEngineUpdateOnlyTouchesWovenGamesPrefixes() throws {
        let paths = Paths(home: home, steamApp: home.appending(path: "Steam.app"))
        try put("log", compat.appending(path: "wovengames-run.log"))
        let other = compat.deletingLastPathComponent().appending(path: "456")
        try put("proton", other.appending(path: "pfx/system.reg"))
        var lines: [String] = []
        PrefixSnapshots.beforeEngineUpdate(paths: paths) { lines.append($0) }
        XCTAssertEqual(PrefixSnapshots(compatData: compat).list().map(\.automatic), [true])
        XCTAssertEqual(PrefixSnapshots(compatData: other).list(), [])
        XCTAssertEqual(lines.count, 1)
    }
}
