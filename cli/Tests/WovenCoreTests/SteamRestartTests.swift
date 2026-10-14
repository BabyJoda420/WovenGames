import XCTest
@testable import WovenCore

/// Patching and unpatching quit Steam; it must come back if it was running before.
final class SteamRestartTests: XCTestCase {
    struct Boom: Error {}

    func testStartsSteamAgainWhenItWasRunning() throws {
        var started = 0
        var lines: [String] = []
        try SteamPatcher.restartingSteam(if: true, log: { lines.append($0) }, start: { started += 1 }) {}
        XCTAssertEqual(started, 1)
        XCTAssertEqual(lines, ["starting Steam again"])
    }

    func testLeavesSteamAloneWhenItWasNotRunning() throws {
        var started = 0
        var lines: [String] = []
        try SteamPatcher.restartingSteam(if: false, log: { lines.append($0) }, start: { started += 1 }) {}
        XCTAssertEqual(started, 0)
        XCTAssertEqual(lines, [])
    }

    func testStartsSteamAgainAfterAFailureAndKeepsTheError() {
        var started = 0
        XCTAssertThrowsError(try SteamPatcher.restartingSteam(if: true, log: { _ in }, start: { started += 1 }) {
            throw Boom()
        }) { XCTAssertTrue($0 is Boom) }
        XCTAssertEqual(started, 1)
    }

    func testStartsSteamOnlyAfterTheWork() throws {
        var events: [String] = []
        try SteamPatcher.restartingSteam(if: true, log: { _ in }, start: { events.append("start") }) {
            events.append("patch")
        }
        XCTAssertEqual(events, ["patch", "start"])
    }

    func testUnmanagedSteamIsNeverReportedRunning() throws {
        var patcher = SteamPatcher(paths: Paths(home: FileManager.default.temporaryDirectory))
        patcher.manageSteamProcess = false
        XCTAssertFalse(try patcher.quitSteam(log: { _ in }))
    }
}
