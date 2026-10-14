import Foundation
import XCTest
@testable import WovenCore

/// WOVEN_RUNNER in a game's settings: one game on another installed runner.
final class PerGameRunnerTests: XCTestCase {
    var home: URL!
    var paths: Paths!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "woven-runner-\(UUID().uuidString)")
        paths = Paths(home: home, steamApp: home.appending(path: "Steam.app"))
        try addRunner("stable")
        try addRunner("ue5-fix")
        try FileManager.default.createSymbolicLink(atPath: paths.currentRunner.path(percentEncoded: false), withDestinationPath: "stable")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func addRunner(_ id: String) throws {
        let root = paths.runners.appending(path: id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"id":"\#(id)","kind":"selfbuilt","arch":"x86_64"}"#.write(to: root.appending(path: "runner.json"), atomically: true, encoding: .utf8)
    }

    func testSettingRoundTrip() {
        var settings = GameSettings()
        settings.runner = "ue5-fix"
        XCTAssertEqual(settings.text, "WOVEN_RUNNER=ue5-fix\n")
        XCTAssertEqual(GameSettings(parsing: settings.text).runner, "ue5-fix")
        XCTAssertEqual(settings.summary, "ue5-fix")
        // the default writes nothing
        XCTAssertEqual(GameSettings().text, "")
    }

    func testGameRunsOnItsOwnRunner() {
        let store = RunnerStore(paths: paths)
        var settings = GameSettings()
        XCTAssertEqual(store.runner(for: settings)?.id, "stable")
        settings.runner = "ue5-fix"
        XCTAssertEqual(store.runner(for: settings)?.id, "ue5-fix")
    }

    func testUnknownOrUnsafeNamesFallBackToCurrent() {
        let store = RunnerStore(paths: paths)
        for name in ["missing", "current", "../stable", ".hidden", "a/b"] {
            var settings = GameSettings()
            settings.runner = name
            XCTAssertEqual(store.runner(for: settings)?.id, "stable", name)
        }
    }
}
