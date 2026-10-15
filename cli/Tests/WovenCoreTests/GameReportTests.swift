import Foundation
import XCTest
@testable import WovenCore

final class GameReportTests: XCTestCase {
    func testParsingFullExample() {
        let text = """
        CX_GRAPHICS_BACKEND=d3dmetal
        WOVEN_GAME_ARGS=-dx11
        #! rating=playable
        #! tested=MacBook Air (M4, 16 GB)
        #! note=About 35 fps at 1280x832 on the lowest preset. Looks rough, but plays.
        #! note=Don't use DXMT: it draws the shadows as a checkerboard.
        """
        guard let report = GameReport(parsing: text) else {
            XCTFail("expected report to parse")
            return
        }
        XCTAssertEqual(report.rating, .playable)
        XCTAssertEqual(report.rating?.label, "Playable with compromises")
        XCTAssertEqual(report.tested, "MacBook Air (M4, 16 GB)")
        XCTAssertEqual(report.notes.count, 2)
        XCTAssertEqual(report.notes[0], "About 35 fps at 1280x832 on the lowest preset. Looks rough, but plays.")
        XCTAssertEqual(report.notes[1], "Don't use DXMT: it draws the shadows as a checkerboard.")
    }

    func testNoHashBangLinesReturnsNil() {
        let text = """
        CX_GRAPHICS_BACKEND=d3dmetal
        # just a regular comment
        WOVEN_RETINA=1
        """
        XCTAssertNil(GameReport(parsing: text))
        XCTAssertNil(GameReport(parsing: ""))
    }

    func testUnknownRatingKeepsNotes() {
        let text = """
        #! rating=superb
        #! tested=Mac Studio
        #! note=Runs at 120 fps
        """
        guard let report = GameReport(parsing: text) else {
            XCTFail("expected report to parse with notes")
            return
        }
        XCTAssertNil(report.rating)
        XCTAssertEqual(report.tested, "Mac Studio")
        XCTAssertEqual(report.notes, ["Runs at 120 fps"])
    }

    func testNoRatingAndNoNotesReturnsNil() {
        let text = """
        #! tested=MacBook Air
        #! unknown_key=ignored
        """
        XCTAssertNil(GameReport(parsing: text), "tested alone without rating or notes is nil")
    }

    func testCapsAt300CharsAndSixNotes() {
        let longNote = String(repeating: "a", count: 350)
        var text = "#! rating=great\n"
        for i in 1...10 {
            text += "#! note=Note \(i): \(longNote)\n"
        }
        guard let report = GameReport(parsing: text) else {
            XCTFail("expected report")
            return
        }
        XCTAssertEqual(report.rating, .great)
        XCTAssertEqual(report.rating?.label, "Runs well")
        XCTAssertEqual(report.notes.count, 6, "at most 6 notes kept")
        for note in report.notes {
            XCTAssertEqual(note.count, 300, "each note capped at 300 characters")
        }
    }

    func testNoSpaceAfterHashBangAccepted() {
        let text = """
        #!rating=poor
        #!tested=Mac mini (M1, 8 GB)
        #!note=Stutters frequently
        """
        guard let report = GameReport(parsing: text) else {
            XCTFail("expected report")
            return
        }
        XCTAssertEqual(report.rating, .poor)
        XCTAssertEqual(report.rating?.label, "Runs poorly")
        XCTAssertEqual(report.tested, "Mac mini (M1, 8 GB)")
        XCTAssertEqual(report.notes, ["Stutters frequently"])
    }

    func testAllRatingLabels() {
        XCTAssertEqual(GameReport.Rating.great.label, "Runs well")
        XCTAssertEqual(GameReport.Rating.playable.label, "Playable with compromises")
        XCTAssertEqual(GameReport.Rating.poor.label, "Runs poorly")
        XCTAssertEqual(GameReport.Rating.broken.label, "Doesn't work")
    }

    func testLoadFromTempPaths() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "woven-gamereport-\(UUID().uuidString)")
        let paths = Paths(home: home)
        defer { try? FileManager.default.removeItem(at: home) }

        let compatDir = paths.support.appending(path: "compat")
        try FileManager.default.createDirectory(at: compatDir, withIntermediateDirectories: true)
        let file = compatDir.appending(path: "1903340.env")

        let content = """
        CX_GRAPHICS_BACKEND=d3dmetal
        #! rating=playable
        #! tested=MacBook Air (M4, 16 GB)
        #! note=About 35 fps at 1280x832.
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let loaded = GameReport.load(appID: "1903340", paths: paths)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.rating, .playable)
        XCTAssertEqual(loaded?.tested, "MacBook Air (M4, 16 GB)")
        XCTAssertEqual(loaded?.notes, ["About 35 fps at 1280x832."])

        XCTAssertNil(GameReport.load(appID: "9999999", paths: paths), "non-existent app id returns nil")
    }

    func testCompatSyncSanitizeKeepsHashBangLines() {
        let text = """
        CX_GRAPHICS_BACKEND=d3dmetal
        WOVEN_GAME_ARGS=-dx11
        #! rating=playable
        #! tested=MacBook Air (M4, 16 GB)
        #! note=Playable with compromises
        INVALID_KEY=drop_me
        """
        let (clean, dropped) = CompatSync.sanitize(text)
        XCTAssertTrue(clean.contains("#! rating=playable"))
        XCTAssertTrue(clean.contains("#! tested=MacBook Air (M4, 16 GB)"))
        XCTAssertTrue(clean.contains("#! note=Playable with compromises"))
        XCTAssertTrue(clean.contains("CX_GRAPHICS_BACKEND=d3dmetal"))
        XCTAssertEqual(dropped, ["INVALID_KEY=drop_me"])
    }

    func testGameSettingsParsingWithHashBangLines() {
        let text = """
        CX_GRAPHICS_BACKEND=dxmt
        WOVEN_GAME_ARGS=-dx11
        #! rating=playable
        #! tested=MacBook Air (M4, 16 GB)
        #! note=About 35 fps
        """
        let settings = GameSettings(parsing: text)
        XCTAssertEqual(settings.backend, .dxmt)
        XCTAssertEqual(settings.gameArgs, "-dx11")
        XCTAssertTrue(settings.otherLines.contains("#! rating=playable"))
        XCTAssertTrue(settings.otherLines.contains("#! tested=MacBook Air (M4, 16 GB)"))
        XCTAssertTrue(settings.otherLines.contains("#! note=About 35 fps"))
    }

    func testMacInfoCurrent() {
        let info = MacInfo.current
        XCTAssertFalse(info.chip.isEmpty, "chip should not be empty")
        XCTAssertGreaterThan(info.memoryGB, 0, "memoryGB should be positive")
        XCTAssertEqual(info.description, "\(info.chip), \(info.memoryGB) GB")
    }

    func testMacInfoCustom() {
        let info = MacInfo(chip: "Apple M3 Pro", memoryGB: 18)
        XCTAssertEqual(info.chip, "Apple M3 Pro")
        XCTAssertEqual(info.memoryGB, 18)
        XCTAssertEqual(info.description, "Apple M3 Pro, 18 GB")
    }
}
