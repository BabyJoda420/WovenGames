import Foundation
import XCTest
@testable import WovenCore

final class LaunchFixTests: XCTestCase {
    var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "launch-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func testUnrealEngineDetection() throws {
        let fm = FileManager.default

        // 1. Non-UE folder
        let nonUEDir = try makeTempDir()
        try "".write(to: nonUEDir.appending(path: "game.exe"), atomically: true, encoding: .utf8)
        XCTAssertFalse(LaunchDiagnosis.isUnrealEngine(installDir: nonUEDir))

        // 2. Direct Engine/Binaries
        let ueDir1 = try makeTempDir()
        try fm.createDirectory(at: ueDir1.appending(path: "Engine/Binaries"), withIntermediateDirectories: true)
        XCTAssertTrue(LaunchDiagnosis.isUnrealEngine(installDir: ueDir1))

        // 3. Nested Engine/Binaries (Game/Engine/Binaries)
        let ueDir2 = try makeTempDir()
        try fm.createDirectory(at: ueDir2.appending(path: "MyGame/Engine/Binaries"), withIntermediateDirectories: true)
        XCTAssertTrue(LaunchDiagnosis.isUnrealEngine(installDir: ueDir2))

        // 4. *-Shipping.exe within depth 4
        let ueDir3 = try makeTempDir()
        let binDir = ueDir3.appending(path: "MyGame/Binaries/Win64")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "".write(to: binDir.appending(path: "MyGame-Win64-Shipping.exe"), atomically: true, encoding: .utf8)
        XCTAssertTrue(LaunchDiagnosis.isUnrealEngine(installDir: ueDir3))

        // 5. Depth > 4 (must be ignored)
        let deepDir = try makeTempDir()
        let deepBin = deepDir.appending(path: "level1/level2/level3/level4/level5")
        try fm.createDirectory(at: deepBin, withIntermediateDirectories: true)
        try "".write(to: deepBin.appending(path: "Game-Win64-Shipping.exe"), atomically: true, encoding: .utf8)
        XCTAssertFalse(LaunchDiagnosis.isUnrealEngine(installDir: deepDir))
    }

    /// an installed runner with DXMT and D3DMetal; without one, "engine not installed" comes first
    func makeRunner() throws -> Runner {
        let root = try makeTempDir()
        try #"{"id":"test","kind":"selfbuilt","arch":"x86_64"}"#.write(to: root.appending(path: "runner.json"), atomically: true, encoding: .utf8)
        for dir in ["lib/renderers/dxmt", "lib/renderers/d3dmetal"] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        return try Runner(root: root)
    }

    func testSuggestionUEvsNonUE() throws {
        let runner = try makeRunner()
        let crash = LastRun(backend: "d3dmetal", exitStatus: 1, seconds: 5)

        // Non-UE: suggests switching to DXMT directly
        let nonUEFindings = LaunchDiagnosis.findings(run: crash, launchOptions: nil, runner: runner,
                                                     settings: GameSettings(), isUnreal: false)
        XCTAssertEqual(nonUEFindings.first?.fix, .switchBackend(.dxmt))
        XCTAssertTrue(nonUEFindings.first?.detail.contains("try DXMT") ?? false)
        XCTAssertFalse(nonUEFindings.first?.detail.contains("-dx11") ?? true)

        // UE: suggests switching to DXMT with -dx11
        let ueFindings = LaunchDiagnosis.findings(run: crash, launchOptions: nil, runner: runner,
                                                 settings: GameSettings(), isUnreal: true)
        XCTAssertEqual(ueFindings.first?.fix, .useSettings(backend: .dxmt, gameArgs: "-dx11"))
        XCTAssertTrue(ueFindings.first?.detail.contains("try DXMT with -dx11") ?? false)
    }

    func testGameArgsNotDoubled() {
        XCTAssertEqual(LaunchDiagnosis.addingArg("-dx11", to: ""), "-dx11")
        XCTAssertEqual(LaunchDiagnosis.addingArg("-dx11", to: "-novid"), "-novid -dx11")
        XCTAssertEqual(LaunchDiagnosis.addingArg("-dx11", to: "-dx11"), "-dx11")
        XCTAssertEqual(LaunchDiagnosis.addingArg("-dx11", to: "-novid -dx11"), "-novid -dx11")
        XCTAssertEqual(LaunchDiagnosis.addingArg("-dx11", to: "-dx11 -novid"), "-dx11 -novid")

        var settings = GameSettings()
        settings.apply(backend: .dxmt, gameArgs: "-dx11")
        XCTAssertEqual(settings.backend, .dxmt)
        XCTAssertEqual(settings.gameArgs, "-dx11")

        // Applying again does not duplicate -dx11
        settings.apply(backend: .dxmt, gameArgs: "-dx11")
        XCTAssertEqual(settings.gameArgs, "-dx11")

        // Retains existing args while adding -dx11
        var otherSettings = GameSettings()
        otherSettings.gameArgs = "-novid -console"
        otherSettings.apply(backend: .dxmt, gameArgs: "-dx11")
        XCTAssertEqual(otherSettings.gameArgs, "-novid -console -dx11")
    }

    func testTokenMovingIntoGameSettings() {
        var settings = GameSettings()
        let tokens = [
            "CX_GRAPHICS_BACKEND=dxmt",
            "MTL_HUD_ENABLED=1",
            "WINEMSYNC=0",
            "WOVEN_RETINA=1",
            "WOVEN_RUNNER=experimental",
            "CUSTOM_VAR=hello",
        ]
        settings.apply(tokens: tokens)

        XCTAssertEqual(settings.backend, .dxmt)
        XCTAssertTrue(settings.metalHUD)
        XCTAssertFalse(settings.msync)
        XCTAssertTrue(settings.retina)
        XCTAssertEqual(settings.runner, "experimental")
        XCTAssertEqual(settings.otherLines, ["CUSTOM_VAR=hello"])

        // Applying tokens with an updated unknown key replaces instead of duplicating
        settings.apply(tokens: ["CUSTOM_VAR=world", "EXTRA_KEY=value"])
        XCTAssertEqual(settings.otherLines.count, 2)
        XCTAssertTrue(settings.otherLines.contains("CUSTOM_VAR=world"))
        XCTAssertFalse(settings.otherLines.contains("CUSTOM_VAR=hello"))
        XCTAssertTrue(settings.otherLines.contains("EXTRA_KEY=value"))
    }

    func testCleanedLaunchOptionsString() {
        XCTAssertEqual(SteamLaunchOptions("CX_GRAPHICS_BACKEND=dxmt %command%").cleaned, "%command%")
        XCTAssertEqual(SteamLaunchOptions("CX_GRAPHICS_BACKEND=dxmt %command% -dx11").cleaned, "%command% -dx11")
        XCTAssertEqual(SteamLaunchOptions("MANGOHUD=1 CX_GRAPHICS_BACKEND=dxmt %command% -dx11").cleaned, "MANGOHUD=1 %command% -dx11")
        XCTAssertEqual(SteamLaunchOptions("MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt %command%").cleaned, "%command%")
        XCTAssertEqual(SteamLaunchOptions("%command% -novid").cleaned, "%command% -novid")
        XCTAssertEqual(SteamLaunchOptions("").cleaned, "")
    }

    func testFindingIncludesMisplacedAndCleaned() throws {
        let runner = try makeRunner()
        let options = SteamLaunchOptions("MTL_HUD_ENABLED=1 %command% -novid")
        let findings = LaunchDiagnosis.findings(run: nil, launchOptions: options, runner: runner, settings: GameSettings())

        XCTAssertEqual(findings.first?.fix, .launchOptions("%command% -novid MTL_HUD_ENABLED=1"))
        XCTAssertEqual(findings.first?.misplacedSettings, ["MTL_HUD_ENABLED=1"])
        XCTAssertEqual(findings.first?.cleanedOptions, "%command% -novid")
    }
}
