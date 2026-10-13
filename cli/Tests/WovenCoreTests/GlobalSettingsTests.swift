import Foundation
import XCTest
@testable import WovenCore

// global.env: the app only adds or removes MTL_HUD_ENABLED=1; hand edits stay as written.
final class GlobalSettingsTests: XCTestCase {
    func makeSettings() throws -> GlobalSettings {
        let home = try makeTempDir("global")
        return GlobalSettings(paths: Paths(home: home, steamApp: home.appending(path: "Steam.app")))
    }

    func read(_ s: GlobalSettings) -> String? {
        try? String(contentsOf: s.file, encoding: .utf8)
    }

    func testNoFileMeansOff() throws {
        let s = try makeSettings()
        XCTAssertFalse(s.fpsOverlay)
    }

    func testTurningOnCreatesTheFile() throws {
        let s = try makeSettings()
        try s.setFPSOverlay(true)
        XCTAssertEqual(read(s), "MTL_HUD_ENABLED=1\n")
        XCTAssertTrue(s.fpsOverlay)
    }

    func testTurningOffDeletesAnOtherwiseEmptyFile() throws {
        let s = try makeSettings()
        try s.setFPSOverlay(true)
        try s.setFPSOverlay(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.file.path(percentEncoded: false)))
        XCTAssertFalse(s.fpsOverlay)
        // off with no file is fine too
        try s.setFPSOverlay(false)
        XCTAssertNil(read(s))
    }

    func testOtherLinesStayVerbatim() throws {
        let s = try makeSettings()
        let original = "# my tweaks\n  WOVEN_RETINA=1\n\nDXMT_LOG_LEVEL=none\r\n"
        try put(original, s.file)
        XCTAssertFalse(s.fpsOverlay)
        try s.setFPSOverlay(true)
        XCTAssertEqual(read(s), original + "MTL_HUD_ENABLED=1\n")
        XCTAssertTrue(s.fpsOverlay)
        try s.setFPSOverlay(false)
        XCTAssertEqual(read(s), original)
    }

    func testHandWrittenValuesAreReplaced() throws {
        let s = try makeSettings()
        try put("MTL_HUD_ENABLED=0\nWOVEN_RETINA=1\n MTL_HUD_ENABLED = 1\n", s.file)
        try s.setFPSOverlay(true)
        // the =0 line goes, or the run script would keep it (first value wins)
        XCTAssertEqual(read(s), "WOVEN_RETINA=1\nMTL_HUD_ENABLED=1\n")
        try put("MTL_HUD_ENABLED=1\n# MTL_HUD_ENABLED=1\n", s.file)
        XCTAssertTrue(s.fpsOverlay)
        try s.setFPSOverlay(false)
        XCTAssertEqual(read(s), "# MTL_HUD_ENABLED=1\n")
        XCTAssertFalse(s.fpsOverlay)
    }

    func testOnlyBlankLinesLeftDeletesTheFile() throws {
        let s = try makeSettings()
        try put("\n  \nMTL_HUD_ENABLED=1\n", s.file)
        XCTAssertTrue(s.fpsOverlay)
        try s.setFPSOverlay(false)
        XCTAssertNil(read(s))
    }

    func testFileWithoutFinalNewline() throws {
        let s = try makeSettings()
        try put("WOVEN_RETINA=1", s.file)
        try s.setFPSOverlay(true)
        XCTAssertEqual(read(s), "WOVEN_RETINA=1\nMTL_HUD_ENABLED=1\n")
    }
}
