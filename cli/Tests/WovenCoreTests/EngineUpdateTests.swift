import Foundation
import XCTest
@testable import WovenCore

final class EngineUpdateTests: XCTestCase {
    // Builds GitHubRelease instances with realistic asset structure matching
    // existing tests in cli/Tests/WovenCoreTests/V02Tests.swift:102-127.
    static func release(
        _ tag: String,
        prerelease: Bool = false,
        draft: Bool = false,
        engine: Bool = true,
        app: Bool = true
    ) throws -> GitHubRelease {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        var assets: [String] = []
        if engine {
            assets.append(#"{"name":"wovengames-engine-\#(v).tar.xz","browser_download_url":"https://github.com/x/releases/download/\#(tag)/wovengames-engine-\#(v).tar.xz","size":100}"#)
            assets.append(#"{"name":"wovengames-engine-\#(v).tar.xz.sha256","browser_download_url":"https://github.com/x/releases/download/\#(tag)/wovengames-engine-\#(v).tar.xz.sha256","size":90}"#)
        }
        if app {
            assets.append(#"{"name":"WovenGames-\#(v).zip","browser_download_url":"https://github.com/x/releases/download/\#(tag)/WovenGames-\#(v).zip","size":200}"#)
        }
        let json = #"{"tag_name":"\#(tag)","name":"WovenGames \#(v)","prerelease":\#(prerelease),"draft":\#(draft),"html_url":"https://github.com/x/releases/tag/\#(tag)","body":null,"created_at":"2026-10-01T00:00:00Z","assets":[\#(assets.joined(separator: ","))]}"#
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    private func makePaths(engineVersion: String? = nil) throws -> Paths {
        let home = try makeTempDir("engine-update-test")
        let paths = Paths(home: home)
        if let engineVersion {
            try put(engineVersion, paths.engineVersionFile)
        }
        return paths
    }

    // MARK: - Baseline

    func testBaselineEngineOlder() throws {
        let paths = try makePaths(engineVersion: "0.2.0")
        let app = try XCTUnwrap(Version("0.3.0"))
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.2.0"))
    }

    func testBaselineEngineEqual() throws {
        let paths = try makePaths(engineVersion: "0.3.0")
        let app = try XCTUnwrap(Version("0.3.0"))
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.3.0"))
    }

    func testBaselineEngineNewer() throws {
        let paths = try makePaths(engineVersion: "0.4.0")
        let app = try XCTUnwrap(Version("0.3.0"))
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.3.0"), "a newer engine does not raise or lower the baseline above the app")
    }

    func testBaselineEngineMissing() throws {
        let paths = try makePaths(engineVersion: nil)
        let app = try XCTUnwrap(Version("0.3.0"))
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.3.0"), "missing engine.version defaults to app version")
    }

    func testBaselineLocalBuild() throws {
        let paths = try makePaths(engineVersion: "local build\n")
        let app = try XCTUnwrap(Version("0.3.0"))
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.3.0"), "unversioned local build defaults to app version")
    }

    func testBaselineTrailingNewline() throws {
        let paths = try makePaths(engineVersion: "0.2.0\n")
        let app = try XCTUnwrap(Version("0.3.0"))
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.2.0"), "trailing newline is trimmed when reading engine version")
    }

    func testBaselineBetaVsFinalOrdering() throws {
        let appFinal = try XCTUnwrap(Version("0.3.0"))
        let engineBeta = try XCTUnwrap(Version("0.3.0-beta.3"))

        // Engine is beta.3, app is 0.3.0 final -> beta.3 is older, baseline is beta.3
        let paths1 = try makePaths(engineVersion: "0.3.0-beta.3")
        XCTAssertEqual(UpdateCheck.baseline(app: appFinal, paths: paths1), engineBeta)

        // Engine is 0.3.0 final, app is beta.3 -> engine is newer/not older, baseline is app (beta.3)
        let paths2 = try makePaths(engineVersion: "0.3.0")
        XCTAssertEqual(UpdateCheck.baseline(app: engineBeta, paths: paths2), engineBeta)
    }

    // MARK: - onlyEngine

    func testOnlyEngineForApp() throws {
        let app = try XCTUnwrap(Version("0.3.0"))

        let sameRelease = try Self.release("v0.3.0")
        XCTAssertTrue(sameRelease.onlyEngine(forApp: app), "same version requires only engine")

        let olderRelease = try Self.release("v0.2.0")
        XCTAssertTrue(olderRelease.onlyEngine(forApp: app), "older release is not newer than app")

        let newerRelease = try Self.release("v0.3.1")
        XCTAssertFalse(newerRelease.onlyEngine(forApp: app), "newer release needs app update too")

        let olderBeta = try Self.release("v0.3.0-beta.1", prerelease: true)
        XCTAssertTrue(olderBeta.onlyEngine(forApp: app), "beta before final is not newer than app")

        let finalForBetaApp = try Self.release("v0.3.0")
        let betaApp = try XCTUnwrap(Version("0.3.0-beta.1"))
        XCTAssertFalse(finalForBetaApp.onlyEngine(forApp: betaApp), "final release is newer than beta app")

        let unversioned = try Self.release("nightly")
        XCTAssertFalse(unversioned.onlyEngine(forApp: app), "unversioned release returns false")
    }

    // MARK: - UpdateCheck.pick

    func testPickWithOlderEnginePicksMatchingRelease() throws {
        let app = try XCTUnwrap(Version("0.3.0"))
        let paths = try makePaths(engineVersion: "0.2.0")
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.2.0"))

        let r020 = try Self.release("v0.2.0")
        let r030 = try Self.release("v0.3.0")
        let releases = [r030, r020]

        let check = UpdateCheck(current: baseline, includeBetas: false)
        let picked = try XCTUnwrap(check.pick(from: releases))
        XCTAssertEqual(picked.tag_name, "v0.3.0")
        XCTAssertTrue(picked.onlyEngine(forApp: app), "picked release only needs engine because app is already at 0.3.0")
    }

    func testPickWhenBothAreCurrentReturnsNothing() throws {
        let app = try XCTUnwrap(Version("0.3.0"))
        let paths = try makePaths(engineVersion: "0.3.0")
        let baseline = UpdateCheck.baseline(app: app, paths: paths)
        XCTAssertEqual(baseline, Version("0.3.0"))

        let r020 = try Self.release("v0.2.0")
        let r030 = try Self.release("v0.3.0")
        let releases = [r030, r020]

        let check = UpdateCheck(current: baseline, includeBetas: false)
        XCTAssertNil(check.pick(from: releases), "no update offered when app and engine are both current")
    }

    func testPickExcludesBetasWhenIncludeBetasIsFalse() throws {
        let app = try XCTUnwrap(Version("0.3.0"))
        let paths = try makePaths(engineVersion: "0.3.0")
        let baseline = UpdateCheck.baseline(app: app, paths: paths)

        let r030 = try Self.release("v0.3.0")
        let r031Beta = try Self.release("v0.3.1-beta.1", prerelease: true)
        let releases = [r031Beta, r030]

        // Betas excluded:
        let noBetasCheck = UpdateCheck(current: baseline, includeBetas: false)
        XCTAssertNil(noBetasCheck.pick(from: releases), "betas are excluded when includeBetas is false")

        // Betas included:
        let withBetasCheck = UpdateCheck(current: baseline, includeBetas: true)
        let picked = try XCTUnwrap(withBetasCheck.pick(from: releases))
        XCTAssertEqual(picked.tag_name, "v0.3.1-beta.1")
        XCTAssertFalse(picked.onlyEngine(forApp: app), "newer beta needs both app and engine")
    }
}
