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

    /// From `sample` of steam_osx stuck closing (build 1791918634), shortened.
    static let stuckSample = """
        Call graph:
            2267 Thread_12619206   DispatchQueue_1: com.apple.main-thread  (serial)
            + 2267 start  (in dyld) + 6700  [0x195f44dac]
            +   2267 dyld4::LibSystemHelpersWrapper::exit(int) const  (in dyld) + 164  [0x195f45250]
            +       2267 exit  (in libsystem_c.dylib) + 44  [0x1960599ac]
            +         2267 __cxa_finalize_ranges  (in libsystem_c.dylib) + 436  [0x196059bc0]
            +           2267 ???  (in chromehtml.dylib)  load address 0x112650000 + 0x54158  [0x1126a4158]
            +                         ! 2262 usleep  (in libsystem_c.dylib) + 68  [0x19603ef6c]
            2267 Thread_12619223: com.apple.NSEventThread
              2267 thread_start  (in libsystem_pthread.dylib) + 8  [0x196013cd0]
        """

    /// A running Steam: exit() only shows up on another thread, not the main one.
    static let busySample = """
        Call graph:
            812 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 812 start  (in dyld) + 6700  [0x195f44dac]
            +   812 main  (in steam_osx) + 120  [0x100001000]
            +     812 __CFRunLoopRun  (in CoreFoundation) + 1172  [0x19a1dc310]
            812 Thread_2: worker
              812 exit  (in libsystem_c.dylib) + 44  [0x1960599ac]
        """

    func testStuckInExitOnlyWhenMainThreadIsExiting() throws {
        XCTAssertTrue(SteamPatcher.stuckInExit(sample: Self.stuckSample))
        XCTAssertFalse(SteamPatcher.stuckInExit(sample: Self.busySample))
        XCTAssertFalse(SteamPatcher.stuckInExit(sample: ""), "no sample: never force-quit")
        let regex = try Regex(SteamPatcher.helperPattern)
        XCTAssertNotNil("/Applications/Steam.app/Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper (Renderer)".firstMatch(of: regex))
        XCTAssertNil("/Users/x/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx".firstMatch(of: regex))
        XCTAssertNil("/Users/x/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/ipcserver".firstMatch(of: regex))
    }

    /// sample works on one's own process without extra permission (here: the test runner itself).
    func testSampleReadsAProcess() {
        let text = SteamPatcher.sampleMainThread(pid: String(getpid()))
        XCTAssertTrue(text.contains("com.apple.main-thread"))
        XCTAssertFalse(SteamPatcher.stuckInExit(sample: text))
    }
}
