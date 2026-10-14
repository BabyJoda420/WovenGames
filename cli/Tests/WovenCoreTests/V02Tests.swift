import Foundation
import XCTest
@testable import WovenCore

// Tests for the v0.2 modules: updates, live recommendations, launch diagnosis, art, sessions,
// problem reports and the one-step Steam update. Everything runs in a fake home.

extension XCTestCase {
    /// An empty folder under the temporary directory, removed after the test.
    func makeTempDir(_ tag: String = "wv") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func put(_ text: String, _ url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }
    }
}

/// Answers requests from a table of canned replies and records what was asked.
final class StubURLProtocol: URLProtocol {
    struct Reply { var status: Int; var body: Data }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: Reply] = [:]
        private var log: [String] = []

        func set(_ url: String, status: Int = 200, _ body: Data) { lock.withLock { replies[url] = Reply(status: status, body: body) } }
        func remove(_ url: String) { lock.withLock { replies[url] = nil } }
        func reply(for url: String) -> Reply? { lock.withLock { log.append(url); return replies[url] } }
        /// requests made to `host`
        func requests(host: String) -> [String] { lock.withLock { log.filter { URL(string: $0)?.host == host } } }
        func clear(host: String) { lock.withLock { log.removeAll { URL(string: $0)?.host == host } } }
    }

    static let store = Store()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let reply = Self.store.reply(for: url.absoluteString) ?? Reply(status: 404, body: Data())
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Collects log lines from a @Sendable log closure.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

// MARK: - Updates

final class UpdatesTests: XCTestCase {
    func v(_ s: String) -> Version { Version(s)! }

    func testVersionOrdering() {
        let ordered = ["0.1.9", "0.2.0-alpha", "0.2.0-beta", "0.2.0-beta.1", "0.2.0-beta.2", "0.2.0-beta.10",
                       "0.2.0-rc.1", "0.2.0", "0.2.1", "0.10.0", "1.0.0"]
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(v(a), v(b), "\(a) < \(b)")
            XCTAssertFalse(v(b) < v(a), "not \(b) < \(a)")
            XCTAssertNotEqual(v(a), v(b))
        }
        XCTAssertEqual(v("v0.2.0"), v("0.2.0"))
        XCTAssertEqual(v("0.2"), v("0.2.0"))
        XCTAssertEqual(v("v0.2.0-beta.1"), v("0.2.0-beta.1"))
        XCTAssertLessThan(v("v0.2.0-beta.1"), v("0.2"))
        XCTAssertEqual(v("v0.2.0-beta.1").prerelease, "beta.1")
        XCTAssertTrue(v("0.2.0-beta.1").isPrerelease)
        XCTAssertFalse(v("0.2.0").isPrerelease)
        XCTAssertEqual(v("v0.2.0-beta.1").description, "0.2.0-beta.1")
        XCTAssertEqual(v(" 0.2.1\n").description, "0.2.1")
        XCTAssertNil(Version(""))
        XCTAssertNil(Version("v"))
        XCTAssertNil(Version("latest"))
        XCTAssertNil(Version("0.x.1"))
    }

    static func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, engine: Bool = true, app: Bool = true) -> String {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        var assets: [String] = []
        if engine {
            assets.append(#"{"name":"wovengames-engine-\#(v).tar.xz","browser_download_url":"https://github.com/x/releases/download/\#(tag)/wovengames-engine-\#(v).tar.xz","size":100}"#)
            assets.append(#"{"name":"wovengames-engine-\#(v).tar.xz.sha256","browser_download_url":"https://github.com/x/releases/download/\#(tag)/wovengames-engine-\#(v).tar.xz.sha256","size":90}"#)
        }
        if app {
            assets.append(#"{"name":"WovenGames-\#(v).zip","browser_download_url":"https://github.com/x/releases/download/\#(tag)/WovenGames-\#(v).zip","size":200}"#)
        }
        return #"{"tag_name":"\#(tag)","name":"WovenGames \#(v)","prerelease":\#(prerelease),"draft":\#(draft),"html_url":"https://github.com/x/releases/tag/\#(tag)","body":null,"created_at":"2026-10-01T00:00:00Z","assets":[\#(assets.joined(separator: ","))]}"#
    }

    static let fixture = "[" + [
        release("v0.3.0", draft: true),                   // drafts are never offered
        release("v0.2.5", engine: false),                  // no engine archive
        release("nightly"),                                // not a version
        release("v0.2.1-beta.2", prerelease: true),
        release("v0.2.1-beta.10", prerelease: true),
        release("v0.2.0"),
        release("v0.1.1"),
    ].joined(separator: ",") + "]"

    func releases() throws -> [GitHubRelease] {
        try JSONDecoder().decode([GitHubRelease].self, from: Data(Self.fixture.utf8))
    }

    func testPick() throws {
        let all = try releases()
        XCTAssertEqual(all.count, 7)
        func pick(_ current: String, betas: Bool) -> String? {
            UpdateCheck(current: v(current), includeBetas: betas).pick(from: all)?.tag_name
        }
        XCTAssertEqual(pick("0.1.1", betas: false), "v0.2.0")
        XCTAssertEqual(pick("0.1.1", betas: true), "v0.2.1-beta.10")
        XCTAssertNil(pick("0.2.0", betas: false), "not newer than current")
        XCTAssertEqual(pick("0.2.0", betas: true), "v0.2.1-beta.10")
        XCTAssertNil(pick("0.2.1-beta.10", betas: true), "same version")
        XCTAssertNil(pick("0.2.1", betas: true), "a beta of the installed release is older")
        XCTAssertEqual(pick("0.2.0-beta.3", betas: false), "v0.2.0", "the release after a beta")
        XCTAssertNil(pick("0.3.0", betas: true))

        let r020 = try XCTUnwrap(all.first { $0.tag_name == "v0.2.0" })
        XCTAssertEqual(r020.engineArchive?.lastPathComponent, "wovengames-engine-0.2.0.tar.xz")
        XCTAssertEqual(r020.appArchive?.lastPathComponent, "WovenGames-0.2.0.zip")
        XCTAssertNil(all.first { $0.tag_name == "v0.2.5" }?.engineArchive)
    }

    func testNewerAsksGitHub() async throws {
        let host = "gh-\(UUID().uuidString.prefix(8)).test"
        var check = UpdateCheck(current: v("0.1.1"), includeBetas: false)
        check.api = URL(string: "https://\(host)/releases")!
        StubURLProtocol.store.set(check.api.absoluteString, Data(Self.fixture.utf8))
        let session = StubURLProtocol.session()
        let newer = try await check.newer(session: session)
        XCTAssertEqual(newer?.tag_name, "v0.2.0")

        StubURLProtocol.store.set(check.api.absoluteString, status: 403, Data("rate limited".utf8))
        do {
            _ = try await check.newer(session: session)
            XCTFail("a refused request throws")
        } catch {}
    }
}

// MARK: - CompatSync

final class CompatSyncTests: XCTestCase {
    func testSanitize() {
        let input = """
        # DXMT works for this game
        CX_GRAPHICS_BACKEND=dxmt

          WOVEN_GAME_ARGS=-dx11
        WINEDLLPATH_PREPEND=/tmp/evil
        DYLD_INSERT_LIBRARIES=/tmp/evil.dylib
        rm -rf x
        mtl_hud_enabled=1
        MTL_HUD_ENABLED
        =WOVEN_X=1
        WINEDEBUG=-all
        D3DM_ENABLE_METALFX=1
        """
        let out = CompatSync.sanitize(input)
        XCTAssertEqual(out.text, "# DXMT works for this game\nCX_GRAPHICS_BACKEND=dxmt\nWOVEN_GAME_ARGS=-dx11\nWINEDEBUG=-all\nD3DM_ENABLE_METALFX=1\n")
        XCTAssertEqual(out.dropped, ["WINEDLLPATH_PREPEND=/tmp/evil", "DYLD_INSERT_LIBRARIES=/tmp/evil.dylib", "rm -rf x",
                                     "mtl_hud_enabled=1", "MTL_HUD_ENABLED", "=WOVEN_X=1"])
    }

    func testGitBlobSHAMatchesGit() throws {
        let dir = try makeTempDir()
        for sample in ["", "hello world\n", "CX_GRAPHICS_BACKEND=dxmt\n# ünïcode\n"] {
            let file = dir.appending(path: "sample")
            try Data(sample.utf8).write(to: file)
            let git = Shell.capture("/usr/bin/git", ["hash-object", file.path(percentEncoded: false)])
            XCTAssertEqual(git.status, 0, git.output)
            XCTAssertEqual(CompatSync.gitBlobSHA(Data(sample.utf8)), git.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(CompatSync.gitBlobSHA(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    // a fake GitHub: compat/ listing plus raw files
    var host = ""
    var files: [String: String] = [:]
    /// what the raw download answers instead of the listed content
    var served: [String: String] = [:]

    var listingURL: URL { URL(string: "https://\(host)/repos/x/contents/compat?ref=main")! }
    func raw(_ name: String) -> String { "https://\(host)/raw/main/compat/\(name)" }

    func publish() throws {
        var entries: [[String: Any]] = [
            ["name": "README.md", "sha": CompatSync.gitBlobSHA(Data("hi".utf8)), "size": 2, "type": "file", "download_url": raw("README.md")],
            ["name": "old", "sha": "0000", "size": 0, "type": "dir", "download_url": NSNull()],
            ["name": "9.env", "sha": "1111", "size": 20_000, "type": "file", "download_url": raw("9.env")],
        ]
        StubURLProtocol.store.set(raw("README.md"), Data("hi".utf8))
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let data = Data(text.utf8)
            entries.append(["name": name, "path": "compat/\(name)", "sha": CompatSync.gitBlobSHA(data), "size": data.count,
                            "type": "file", "download_url": raw(name)])
            StubURLProtocol.store.set(raw(name), Data((served[name] ?? text).utf8))
        }
        StubURLProtocol.store.set(listingURL.absoluteString, try JSONSerialization.data(withJSONObject: entries))
    }

    func makeSync() throws -> (CompatSync, URL) {
        host = "compat-\(UUID().uuidString.prefix(8)).test"
        let home = try makeTempDir()
        var sync = CompatSync(paths: Paths(home: home, steamApp: home.appending(path: "Steam.app")))
        sync.listing = listingURL
        return (sync, sync.folder)
    }

    func downloads() -> [String] { StubURLProtocol.store.requests(host: host).filter { $0.contains("/raw/") } }

    func testSyncWritesSanitizedFilesAndSkipsWhatItHas() async throws {
        let (sync, folder) = try makeSync()
        let session = StubURLProtocol.session()
        files = ["1874000.env": "# DXMT\nCX_GRAPHICS_BACKEND=dxmt\nWOVEN_GAME_ARGS=-dx11\nWINEDLLPATH_PREPEND=/evil\n",
                 "2000.env": "MTL_HUD_ENABLED=1\n"]
        try publish()
        let log = LogLines()

        // first sync writes both, without the setting a recommendation may not set
        var r = try await sync.run(session: session, log: { log.add($0) })
        XCTAssertEqual(r, .init(updated: ["1874000.env", "2000.env"]))
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "1874000.env"), encoding: .utf8),
                       "# DXMT\nCX_GRAPHICS_BACKEND=dxmt\nWOVEN_GAME_ARGS=-dx11\n")
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "2000.env"), encoding: .utf8), "MTL_HUD_ENABLED=1\n")
        XCTAssertTrue(log.all.contains { $0.contains("WINEDLLPATH_PREPEND") && $0.contains("ignored") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "README.md").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "9.env").path(percentEncoded: false)))
        XCTAssertEqual(Set(downloads()), [raw("1874000.env"), raw("2000.env")])

        // unchanged upstream: only the listing is fetched
        StubURLProtocol.store.clear(host: host)
        r = try await sync.run(force: true, session: session)
        XCTAssertEqual(r, .init())
        XCTAssertEqual(downloads(), [])
        XCTAssertEqual(StubURLProtocol.store.requests(host: host), [listingURL.absoluteString])

        // within the interval and not forced: nothing is asked at all
        StubURLProtocol.store.clear(host: host)
        r = try await sync.run(session: session)
        XCTAssertEqual(r, .init(skipped: true))
        XCTAssertEqual(StubURLProtocol.store.requests(host: host), [])

        // an engine reinstall puts its own copy back: synced again
        try put("CX_GRAPHICS_BACKEND=d3dmetal\n", folder.appending(path: "1874000.env"))
        r = try await sync.run(force: true, session: session)
        XCTAssertEqual(r.updated, ["1874000.env"])
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "1874000.env"), encoding: .utf8),
                       "# DXMT\nCX_GRAPHICS_BACKEND=dxmt\nWOVEN_GAME_ARGS=-dx11\n")

        // an upstream change is picked up
        files["2000.env"] = "MTL_HUD_ENABLED=0\n"
        try publish()
        StubURLProtocol.store.clear(host: host)
        r = try await sync.run(force: true, session: session)
        XCTAssertEqual(r.updated, ["2000.env"])
        XCTAssertEqual(downloads(), [raw("2000.env")])
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "2000.env"), encoding: .utf8), "MTL_HUD_ENABLED=0\n")
    }

    func testWithdrawnFilesGoOnlyIfTheSyncWroteThem() async throws {
        let (sync, folder) = try makeSync()
        let session = StubURLProtocol.session()
        files = ["1.env": "WINEMSYNC=0\n", "2.env": "WINEESYNC=1\n", "3.env": "WINEDEBUG=-all\n"]
        try publish()
        try await sync.run(session: session)
        // a file the sync never wrote (shipped with the engine, say)
        try put("CX_GRAPHICS_BACKEND=wined3d\n", folder.appending(path: "4.env"))
        // a synced file that something else replaced since
        try put("CX_GRAPHICS_BACKEND=dxmt\n", folder.appending(path: "3.env"))

        files = ["2.env": "WINEESYNC=1\n"]
        try publish()
        let r = try await sync.run(force: true, session: session)
        XCTAssertEqual(r.removed, ["1.env"])
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: folder.appending(path: "1.env").path(percentEncoded: false)))
        XCTAssertTrue(fm.fileExists(atPath: folder.appending(path: "2.env").path(percentEncoded: false)))
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "3.env"), encoding: .utf8), "CX_GRAPHICS_BACKEND=dxmt\n")
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "4.env"), encoding: .utf8), "CX_GRAPHICS_BACKEND=wined3d\n")
        // and they stay alone afterwards
        let again = try await sync.run(force: true, session: session)
        XCTAssertEqual(again, .init())
        XCTAssertTrue(fm.fileExists(atPath: folder.appending(path: "4.env").path(percentEncoded: false)))
    }

    func testDownloadThatDoesNotMatchTheListingIsSkipped() async throws {
        let (sync, folder) = try makeSync()
        let session = StubURLProtocol.session()
        files = ["1.env": "WINEMSYNC=0\n", "2.env": "WINEESYNC=1\n"]
        served = ["1.env": "WINEDLLPATH_PREPEND=/evil\n"]
        try publish()
        let log = LogLines()
        var r = try await sync.run(session: session, log: { log.add($0) })
        XCTAssertEqual(r.updated, ["2.env"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "1.env").path(percentEncoded: false)))
        XCTAssertTrue(log.all.contains { $0.hasPrefix("1.env:") && $0.contains("did not match") })

        // a failed download is not remembered: the next sync tries again
        served = [:]
        try publish()
        r = try await sync.run(force: true, session: session)
        XCTAssertEqual(r.updated, ["1.env"])
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "1.env"), encoding: .utf8), "WINEMSYNC=0\n")

        // an error page instead of the file is skipped too
        files["1.env"] = "WINEMSYNC=1\n"
        try publish()
        StubURLProtocol.store.set(raw("1.env"), status: 500, Data("WINEMSYNC=1\n".utf8))
        r = try await sync.run(force: true, session: session)
        XCTAssertEqual(r.updated, [])
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "1.env"), encoding: .utf8), "WINEMSYNC=0\n")
    }

    func testListingErrorThrows() async throws {
        let (sync, _) = try makeSync()
        StubURLProtocol.store.set(listingURL.absoluteString, status: 403, Data())
        do {
            try await sync.run(session: StubURLProtocol.session())
            XCTFail("expected an error")
        } catch {}
    }
}

// MARK: - Launch options and diagnosis

final class LaunchDiagnosisTests: XCTestCase {
    func testLaunchOptionsSettingsBeforeCommand() {
        let o = SteamLaunchOptions("MTL_HUD_ENABLED=1 %command%")
        XCTAssertEqual(o.misplacedSettings, ["MTL_HUD_ENABLED=1"])
        XCTAssertTrue(o.hasCommand)
        XCTAssertEqual(o.settings, [])
        XCTAssertEqual(o.corrected, "%command% MTL_HUD_ENABLED=1")
    }

    func testLaunchOptionsAlreadyRight() {
        let o = SteamLaunchOptions("%command% -dx11 CX_GRAPHICS_BACKEND=dxmt")
        XCTAssertEqual(o.misplacedSettings, [])
        XCTAssertTrue(o.hasCommand)
        XCTAssertEqual(o.settings, ["CX_GRAPHICS_BACKEND=dxmt"])
        XCTAssertEqual(o.corrected, "%command% -dx11 CX_GRAPHICS_BACKEND=dxmt")
    }

    func testLaunchOptionsWithoutCommand() {
        // Steam appends options to the command, where the launch script reads the settings
        let o = SteamLaunchOptions("MTL_HUD_ENABLED=1 -foo")
        XCTAssertEqual(o.misplacedSettings, [])
        XCTAssertFalse(o.hasCommand)
        XCTAssertEqual(o.settings, ["MTL_HUD_ENABLED=1"])
    }

    func testIsSetting() {
        XCTAssertTrue(SteamLaunchOptions.isSetting("WINEMSYNC=0"))
        XCTAssertFalse(SteamLaunchOptions.isSetting("=WINE"))
        XCTAssertFalse(SteamLaunchOptions.isSetting("-dx11"))
        XCTAssertFalse(SteamLaunchOptions.isSetting("FOO=1"))
    }

    static let localconfig = """
    "UserLocalConfigStore"
    {
    \t"apps"
    \t{
    \t\t"1874000" { "cloud" { "last_sync_state" "synchronized" } }
    \t}
    \t"Software"
    \t{
    \t\t"Valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"Apps"
    \t\t\t\t{
    \t\t\t\t\t"1874000"
    \t\t\t\t\t{
    \t\t\t\t\t\t"LastPlayed"\t\t"1760000000"
    \t\t\t\t\t\t"LaunchOptions"\t\t"%command% -dx11 CX_GRAPHICS_BACKEND=dxmt"
    \t\t\t\t\t}
    \t\t\t\t\t"2000" { "LaunchOptions" "" }
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    }
    """

    func testFindInNestedLocalConfig() {
        let root = VDF.parse(Self.localconfig)
        XCTAssertEqual(SteamLaunchOptions.find(appID: "1874000", in: root), "%command% -dx11 CX_GRAPHICS_BACKEND=dxmt")
        XCTAssertNil(SteamLaunchOptions.find(appID: "2000", in: root), "empty options are no options")
        XCTAssertNil(SteamLaunchOptions.find(appID: "3", in: root))
    }

    func testReadUsesTheMostRecentAccount() throws {
        let home = try makeTempDir()
        let paths = Paths(home: home, steamApp: home.appending(path: "Steam.app"))
        XCTAssertNil(SteamLaunchOptions.read(appID: "1874000", paths: paths))
        let userdata = paths.steam.userData.appending(path: "userdata")
        let old = Self.localconfig.replacingOccurrences(of: "%command% -dx11 CX_GRAPHICS_BACKEND=dxmt", with: "MTL_HUD_ENABLED=1 %command%")
        try put(old, userdata.appending(path: "111111/config/localconfig.vdf"), modified: Date(timeIntervalSinceNow: -3600))
        try put(Self.localconfig, userdata.appending(path: "222222/config/localconfig.vdf"), modified: Date(timeIntervalSinceNow: -60))
        try FileManager.default.createDirectory(at: userdata.appending(path: "333333"), withIntermediateDirectories: true) // no config
        XCTAssertEqual(SteamLaunchOptions.read(appID: "1874000", paths: paths)?.raw, "%command% -dx11 CX_GRAPHICS_BACKEND=dxmt")
        XCTAssertNil(SteamLaunchOptions.read(appID: "2000", paths: paths))
        // the other account becomes the recent one
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: userdata.appending(path: "111111/config/localconfig.vdf").path(percentEncoded: false))
        XCTAssertEqual(SteamLaunchOptions.read(appID: "1874000", paths: paths)?.raw, "MTL_HUD_ENABLED=1 %command%")
    }

    func makeRunner(d3dmetal: Bool) throws -> Runner {
        let root = try makeTempDir("runner")
        try put(#"{"id":"test","kind":"selfbuilt","arch":"x86_64"}"#, root.appending(path: "runner.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "lib/renderers/dxmt"), withIntermediateDirectories: true)
        if d3dmetal {
            try FileManager.default.createDirectory(at: root.appending(path: "lib/renderers/d3dmetal"), withIntermediateDirectories: true)
        }
        return try Runner(root: root)
    }

    func run(_ body: String) -> LastRun {
        SteamLibrary.lastRun(log: "=== wovengames run Sat Oct 10 18:00:00 CEST 2026 ===\nstart_epoch=1760112000\n" + body)!
    }

    func testNoRunner() {
        let f = LaunchDiagnosis.findings(run: nil, launchOptions: nil, runner: nil, settings: GameSettings())
        XCTAssertEqual(f.map(\.fix), [.installEngine])
        XCTAssertEqual(f.first?.severity, .error)
        XCTAssertEqual(f.first?.title, "The engine is not installed")
    }

    func testD3DMetalMissing() throws {
        let without = try makeRunner(d3dmetal: false)
        var settings = GameSettings()
        settings.backend = .d3dmetal
        XCTAssertEqual(LaunchDiagnosis.findings(run: nil, launchOptions: nil, runner: without, settings: settings).map(\.title),
                       ["D3DMetal is not downloaded"])
        XCTAssertEqual(LaunchDiagnosis.findings(run: nil, launchOptions: nil, runner: without, settings: GameSettings(), detected: .d3dmetal).map(\.fix),
                       [.installEngine])
        XCTAssertEqual(LaunchDiagnosis.findings(run: nil, launchOptions: nil, runner: without, settings: GameSettings(), detected: .dxmt), [])
        XCTAssertEqual(LaunchDiagnosis.findings(run: nil, launchOptions: nil, runner: try makeRunner(d3dmetal: true), settings: settings), [])
    }

    func testForeignPrefix() throws {
        let r = run("""
        === prefix ntdll is aa64 and this compatibility tool wants 8664, reset the game's prefix in the WovenGames app (Games, Reset Prefix) ===
        === aborted during prefix arch check (exit 1) before launch ===
        """)
        let f = LaunchDiagnosis.findings(run: r, launchOptions: nil, runner: try makeRunner(d3dmetal: true), settings: GameSettings())
        XCTAssertEqual(f.count, 1, "one finding, not one per log line")
        XCTAssertEqual(f.first?.fix, .resetPrefix)
        XCTAssertEqual(f.first?.title, "The game's Windows environment came from another tool")
    }

    func testStagingFailure() throws {
        let r = run("=== failed to stage steamclient64.dll ===\n=== game exited status=1 after 2s, killing wine prefix ===\n")
        let f = LaunchDiagnosis.findings(run: r, launchOptions: nil, runner: try makeRunner(d3dmetal: true), settings: GameSettings())
        XCTAssertEqual(f.map(\.fix), [.installEngine])
        XCTAssertTrue(f[0].detail.contains("steamclient64.dll"))
    }

    func testAbortedStageMapping() throws {
        let runner = try makeRunner(d3dmetal: true)
        for (stage, fix) in [("bridge staging", LaunchFinding.Fix.installEngine), ("profile layout", .resetPrefix),
                             ("prefix arch check", .resetPrefix), ("startup", .openLaunchLog)] {
            let r = run("=== aborted during \(stage) (exit 2) before launch ===\n")
            XCTAssertEqual(r.abortedStage, stage)
            let f = LaunchDiagnosis.findings(run: r, launchOptions: nil, runner: runner, settings: GameSettings())
            XCTAssertEqual(f.map(\.fix), [fix], stage)
            XCTAssertTrue(f[0].detail.contains("\"\(stage)\""), f[0].detail)
        }
    }

    func testQuickCrashSuggestsAnotherBackend() throws {
        let with = try makeRunner(d3dmetal: true), without = try makeRunner(d3dmetal: false)
        let crash = run("graphics: dxmt from auto (d3d11)\n=== game exited status=1 after 7s, killing wine prefix ===\n")
        var f = LaunchDiagnosis.findings(run: crash, launchOptions: nil, runner: with, settings: GameSettings())
        XCTAssertEqual(f.map(\.fix), [.switchBackend(.d3dmetal)])
        XCTAssertEqual(f.first?.severity, .warning)
        XCTAssertTrue(f[0].detail.contains("7 seconds"), f[0].detail)
        XCTAssertTrue(f[0].detail.contains("D3DMetal"), f[0].detail)
        f = LaunchDiagnosis.findings(run: crash, launchOptions: nil, runner: without, settings: GameSettings())
        XCTAssertEqual(f.map(\.fix), [.switchBackend(.wined3d)])

        let d3dm = run("graphics: d3dmetal from auto (d3d12)\n=== game exited status=5 after 3s, killing wine prefix ===\n")
        XCTAssertEqual(LaunchDiagnosis.findings(run: d3dm, launchOptions: nil, runner: with, settings: GameSettings()).map(\.fix),
                       [.switchBackend(.dxmt)])
        let unknown = run("=== game exited status=5 after 3s, killing wine prefix ===\n")
        XCTAssertEqual(LaunchDiagnosis.findings(run: unknown, launchOptions: nil, runner: with, settings: GameSettings()).map(\.fix),
                       [.openLaunchLog])
        // a long session or a clean exit is not a crash at start
        let long = run("graphics: dxmt from auto (d3d11)\n=== game exited status=1 after 600s, killing wine prefix ===\n")
        XCTAssertEqual(LaunchDiagnosis.findings(run: long, launchOptions: nil, runner: with, settings: GameSettings()), [])
        let clean = run("graphics: dxmt from auto (d3d11)\n=== game exited status=0 after 5s, killing wine prefix ===\n")
        XCTAssertEqual(LaunchDiagnosis.findings(run: clean, launchOptions: nil, runner: with, settings: GameSettings()), [])
    }

    func testUnknownDurationIsNotAQuickCrash() throws {
        // a run logged by v0.1's launch script ("status=N," without "after Ns") may have lasted hours
        let old = try XCTUnwrap(SteamLibrary.lastRun(log: "=== wovengames run Sat Oct 10 18:00:00 CEST 2026 ===\ngraphics: dxmt from auto (d3d11)\n=== game exited status=1, killing wine prefix ===\n"))
        XCTAssertNil(old.seconds)
        XCTAssertEqual(LaunchDiagnosis.findings(run: old, launchOptions: nil, runner: try makeRunner(d3dmetal: true), settings: GameSettings()), [])
    }

    func testTerminatedSessionIsNoProblem() throws {
        let r = run("""
        graphics: dxmt from auto (d3d11)
        === termination signal received, killing wine prefix ===
        === game exited status=143 after 4s, killing wine prefix ===
        """)
        XCTAssertTrue(r.terminated)
        XCTAssertEqual(LaunchDiagnosis.findings(run: r, launchOptions: nil, runner: try makeRunner(d3dmetal: true), settings: GameSettings()), [])
    }

    func testLaunchOptionFindings() throws {
        let runner = try makeRunner(d3dmetal: true)
        var f = LaunchDiagnosis.findings(run: nil, launchOptions: SteamLaunchOptions("MTL_HUD_ENABLED=1 %command%"),
                                         runner: runner, settings: GameSettings())
        XCTAssertEqual(f.map(\.severity), [.error])
        XCTAssertEqual(f.first?.fix, .launchOptions("%command% MTL_HUD_ENABLED=1"))

        // without %command% the settings reach WovenGames: only the "they win" note
        f = LaunchDiagnosis.findings(run: nil, launchOptions: SteamLaunchOptions("MTL_HUD_ENABLED=1 -foo"), runner: runner, settings: GameSettings())
        XCTAssertEqual(f.map(\.severity), [.info])

        f = LaunchDiagnosis.findings(run: nil, launchOptions: SteamLaunchOptions("%command% -dx11 CX_GRAPHICS_BACKEND=dxmt"),
                                     runner: runner, settings: GameSettings())
        XCTAssertEqual(f.map(\.severity), [.info])
        XCTAssertNil(f.first?.fix)

        // worst first
        f = LaunchDiagnosis.findings(run: nil, launchOptions: SteamLaunchOptions("%command% CX_GRAPHICS_BACKEND=dxmt"),
                                     runner: nil, settings: GameSettings())
        XCTAssertEqual(f.map(\.severity), [.error, .info])
        XCTAssertEqual(LaunchDiagnosis.findings(run: nil, launchOptions: SteamLaunchOptions("%command% -dx11"), runner: runner,
                                                settings: GameSettings()), [])
    }
}

// MARK: - Last run

final class LastRunTests: XCTestCase {
    let header1 = "=== wovengames run Sat Oct 10 18:00:00 CEST 2026 ==="
    let header2 = "=== wovengames run Sat Oct 10 18:05:00 CEST 2026 ==="

    func testAbortedRun() throws {
        let r = try XCTUnwrap(SteamLibrary.lastRun(log: """
        \(header1)
        start_epoch=1760112000
        === prefix ntdll is aa64 and this compatibility tool wants 8664, reset the game's prefix in the WovenGames app (Games, Reset Prefix) ===
        === aborted during prefix arch check (exit 1) before launch ===
        """))
        XCTAssertEqual(r.startEpoch, 1760112000)
        XCTAssertEqual(r.abortedStage, "prefix arch check")
        XCTAssertEqual(r.problem, "aborted during prefix arch check (exit 1) before launch")
        XCTAssertTrue(r.foreignPrefix)
        XCTAssertNil(r.exitStatus)
        XCTAssertNil(r.seconds)
        XCTAssertTrue(r.ended)
    }

    func testOnlyTheLastRunCounts() throws {
        let r = try XCTUnwrap(SteamLibrary.lastRun(log: """
        \(header1)
        start_epoch=1760112000
        === prefix ntdll is aa64 and this compatibility tool wants 8664, reset the game's prefix ===
        === aborted during prefix arch check (exit 1) before launch ===
        \(header2)
        start_epoch=1760112300
        graphics: dxmt from auto (d3d11)
        === failed to stage steamclient64.dll ===
        === termination signal received, killing wine prefix ===
        === game exited status=1 after 7s, killing wine prefix ===
        === wine prefix killed, session ending ===
        """))
        XCTAssertEqual(r.date, "Sat Oct 10 18:05:00 CEST 2026")
        XCTAssertEqual(r.startEpoch, 1760112300)
        XCTAssertFalse(r.foreignPrefix)
        XCTAssertNil(r.abortedStage)
        XCTAssertNil(r.problem)
        XCTAssertEqual(r.stagingFailed, "steamclient64.dll")
        XCTAssertTrue(r.terminated)
        XCTAssertEqual(r.exitStatus, 1)
        XCTAssertEqual(r.seconds, 7)
        XCTAssertTrue(r.ended)
    }

    func testOldExitFormat() throws {
        let r = try XCTUnwrap(SteamLibrary.lastRun(log: "\(header1)\ngraphics: wined3d from settings\n=== game exited status=0, killing wine prefix ===\n"))
        XCTAssertEqual(r.exitStatus, 0)
        XCTAssertNil(r.seconds)
        XCTAssertNil(r.startEpoch)
        XCTAssertFalse(r.terminated)
        XCTAssertTrue(r.ended)
    }

    func testRunStillGoing() throws {
        let r = try XCTUnwrap(SteamLibrary.lastRun(log: "\(header1)\nstart_epoch=5\ngraphics: dxmt from auto (d3d11)\n"))
        XCTAssertFalse(r.ended)
        XCTAssertNil(SteamLibrary.lastRun(log: "nothing here\n"))
    }
}

// MARK: - Launch script

final class RunScriptTests: XCTestCase {
    /// notproton/dylib/feats/compat_run.sh in this checkout
    static let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "notproton/dylib/feats/compat_run.sh")

    /// global.env is the user's to edit (the app writes only the FPS line). A malformed line must
    /// not run as a command through the script's eval, nor stop every game before its log exists.
    /// `getcompatpath` reads global.env and exits before anything else happens.
    func testMalformedGlobalEnvLinesAreSkipped() throws {
        let home = try makeTempDir("wvh")
        let marker = home.appending(path: "ran")
        try put("""
        WINE}; touch \(marker.path(percentEncoded: false)); : ${X=1
        MTL_HUD_ENABLED =1
        WOVEN_RETINA=1

        """, home.appending(path: "Library/Application Support/WovenGames/global.env"))
        let env = ["HOME": home.path(percentEncoded: false), "PATH": "/usr/bin:/bin", "STEAM_COMPAT_DATA_PATH": "/compat/42"]
        let r = Shell.capture("/bin/sh", [Self.script.path(percentEncoded: false), "getcompatpath"], environment: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)), "a global.env line ran as a command")
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(r.output, "/compat/42\n")
    }
}

// MARK: - Library

final class LibraryDuplicateTests: XCTestCase {
    /// The app keys games by app ID (Dictionary(uniqueKeysWithValues:), List ids): one game
    /// found twice would crash it at every refresh.
    func testAGameInTwoLibrariesIsListedOnce() throws {
        let home = try makeTempDir("wvl")
        let paths = Paths(home: home, steamApp: home.appending(path: "Steam.app"))
        let main = paths.steam.userData, external = home.appending(path: "Volumes/Games/SteamLibrary")
        // the default library a second time (trailing slash), and a library holding a copy of the game
        try put("""
        "libraryfolders"
        {
        \t"0" { "path" "\(main.path(percentEncoded: false))/" }
        \t"1" { "path" "\(external.path(percentEncoded: false))" }
        }
        """, main.appending(path: "steamapps/libraryfolders.vdf"))
        for library in [main, external] {
            let steamapps = library.appending(path: "steamapps")
            try put("x", steamapps.appending(path: "common/Double Exposure/game.exe"))
            try put("""
            "AppState"
            {
            \t"appid"\t\t"1874000"
            \t"name"\t\t"Life is Strange: Double Exposure"
            \t"installdir"\t\t"Double Exposure"
            }
            """, steamapps.appending(path: "appmanifest_1874000.acf"))
        }
        let games = SteamLibrary(paths: paths).windowsGames()
        XCTAssertEqual(games.map(\.appID), ["1874000"])
        // the default library wins
        XCTAssertEqual(games.first?.installDir.path(percentEncoded: false),
                       main.appending(path: "steamapps/common/Double Exposure").path(percentEncoded: false))
    }
}

// MARK: - Art

final class SteamArtTests: XCTestCase {
    func testFlatAndHashedLayouts() throws {
        let home = try makeTempDir()
        let paths = Paths(home: home, steamApp: home.appending(path: "Steam.app"))
        let folder = paths.steam.userData.appending(path: "appcache/librarycache/1874000")
        func found(_ art: SteamArt, _ app: String = "1874000") -> String? {
            art.url(appID: app, paths: paths)?.resolvingSymlinksInPath().path(percentEncoded: false)
        }
        func expect(_ url: URL) -> String { url.resolvingSymlinksInPath().path(percentEncoded: false) }

        XCTAssertNil(found(.cover))
        // older client: files directly in the app's folder
        try put("cover", folder.appending(path: "library_600x900.jpg"))
        XCTAssertEqual(found(.cover), expect(folder.appending(path: "library_600x900.jpg")))
        XCTAssertNil(found(.hero))
        XCTAssertNil(found(.cover, "1"))

        // newer client: hashed subfolders; the newest copy is what Steam shows
        let now = Date()
        try put("old", folder.appending(path: "library_hero.jpg"), modified: now.addingTimeInterval(-300))
        try put("a", folder.appending(path: "0a1b2c/library_hero.jpg"), modified: now.addingTimeInterval(-200))
        try put("b", folder.appending(path: "9f8e7d/library_hero.jpg"), modified: now.addingTimeInterval(-100))
        try put("c", folder.appending(path: "5d5d5d/library_hero.jpg"), modified: now.addingTimeInterval(-150))
        XCTAssertEqual(found(.hero), expect(folder.appending(path: "9f8e7d/library_hero.jpg")))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: folder.appending(path: "library_hero.jpg").path(percentEncoded: false))
        XCTAssertEqual(found(.hero), expect(folder.appending(path: "library_hero.jpg")))

        // the header falls back to header.jpg, but library_header.jpg wins when there is one
        try put("h", folder.appending(path: "abcdef/header.jpg"), modified: now)
        XCTAssertEqual(found(.header), expect(folder.appending(path: "abcdef/header.jpg")))
        try put("lh", folder.appending(path: "123456/library_header.jpg"), modified: now.addingTimeInterval(-500))
        XCTAssertEqual(found(.header), expect(folder.appending(path: "123456/library_header.jpg")))
        XCTAssertNil(found(.logo))
    }
}

// MARK: - Sessions

final class GameSessionsTests: XCTestCase {
    func testRunScriptAndRunning() throws {
        let home = try makeTempDir()
        let sessions = GameSessions(paths: Paths(home: home, steamApp: home.appending(path: "Steam.app")))
        let launchers = sessions.launchers
        XCTAssertNil(sessions.runScript(appID: "1874000"), "no pid file")
        XCTAssertEqual(sessions.running(), [])

        try put("garbage\n", launchers.appending(path: "100/run.pid"))
        XCTAssertNil(sessions.runScript(appID: "100"))
        try put("1\n", launchers.appending(path: "101/run.pid"))
        XCTAssertNil(sessions.runScript(appID: "101"))
        try put("\(getpid())\n", launchers.appending(path: "102/run.pid"))
        XCTAssertNil(sessions.runScript(appID: "102"), "a live pid that is not a run script")

        // a stand-in run script (its command line names compat_run)
        let script = home.appending(path: "compat_run")
        try put("sleep 30\nexit 0\n", script)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false)]
        try process.run()
        addTeardownBlock { Shell.capture("/usr/bin/pkill", ["-P", "\(process.processIdentifier)"]); process.terminate(); process.waitUntilExit() }
        let pid = process.processIdentifier
        try put("\(pid)\n", launchers.appending(path: "200/run.pid"))
        try put("\(pid)\n", launchers.appending(path: "abc/run.pid"))
        try FileManager.default.createDirectory(at: launchers.appending(path: "300"), withIntermediateDirectories: true)
        XCTAssertEqual(sessions.runScript(appID: "200"), pid)
        XCTAssertEqual(sessions.running(), ["200"], "non-numeric folders and other pids are ignored")

        // the compat tool's script as Steam starts it: ".../compatibilitytools.d/wovengames-proton/./run"
        let tool = home.appending(path: "compatibilitytools.d/wovengames-proton")
        try put("sleep 30\nexit 0\n", tool.appending(path: "run"))
        let steamStarted = Process()
        steamStarted.executableURL = URL(filePath: "/bin/sh")
        steamStarted.arguments = [tool.path(percentEncoded: false) + "/./run"]
        try steamStarted.run()
        addTeardownBlock { Shell.capture("/usr/bin/pkill", ["-P", "\(steamStarted.processIdentifier)"]); steamStarted.terminate(); steamStarted.waitUntilExit() }
        try put("\(steamStarted.processIdentifier)\n", launchers.appending(path: "400/run.pid"))
        XCTAssertEqual(sessions.runScript(appID: "400"), steamStarted.processIdentifier)
        XCTAssertEqual(sessions.running(), ["200", "400"])
    }

    /// A run script killed outright (Steam's Stop gives up waiting) leaves its run.pid behind.
    /// When that pid later belongs to another game's run script, the stale file must not count:
    /// Force Quit would stop the wrong game.
    func testStalePidFileOfAnotherRunScriptIsIgnored() throws {
        let home = try makeTempDir()
        let sessions = GameSessions(paths: Paths(home: home, steamApp: home.appending(path: "Steam.app")))
        let script = home.appending(path: "compat_run")
        try put("sleep 30\nexit 0\n", script)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false)]
        try process.run()
        addTeardownBlock { Shell.capture("/usr/bin/pkill", ["-P", "\(process.processIdentifier)"]); process.terminate(); process.waitUntilExit() }
        let pid = process.processIdentifier
        // game 31's script wrote its file after it started; game 3's file is from an hour ago
        try put("\(pid)\n", sessions.launchers.appending(path: "31/run.pid"))
        try put("\(pid)\n", sessions.launchers.appending(path: "3/run.pid"), modified: Date(timeIntervalSinceNow: -3600))
        XCTAssertEqual(sessions.runScript(appID: "31"), pid)
        XCTAssertNil(sessions.runScript(appID: "3"), "written before this process existed")
        XCTAssertEqual(sessions.running(), ["31"])
    }
}

// MARK: - Problem report

final class ProblemReportTests: XCTestCase {
    let steamID = "76561198012345678"
    let accountID = "52079950"
    let account = "fakeplayer"
    let persona = "Fake Persona"

    func makeHome() throws -> Paths {
        let home = try makeTempDir("wvr")
        let paths = Paths(home: home, steamApp: home.appending(path: "Steam.app"))
        let steam = paths.steam.userData
        try put("""
        "users"
        {
        \t"\(steamID)"
        \t{
        \t\t"AccountName"\t\t"\(account)"
        \t\t"PersonaName"\t\t"\(persona)"
        \t\t"MostRecent"\t\t"1"
        \t}
        }
        """, steam.appending(path: "config/loginusers.vdf"))
        try put(LaunchDiagnosisTests.localconfig, steam.appending(path: "userdata/\(accountID)/config/localconfig.vdf"))
        return paths
    }

    func leaks(_ text: String, _ paths: Paths) -> [String] {
        let lower = text.lowercased()
        return [paths.home.path(percentEncoded: false), steamID, "76561198099999999", accountID, account, persona.lowercased(), "someone@example.com"]
            .filter { lower.contains($0.lowercased()) }
    }

    func testRedactor() throws {
        let paths = try makeHome()
        let home = paths.home.path(percentEncoded: false)
        let text = """
        prefix at \(home)/Library/Application Support/WovenGames/prefixes/x
        logged in as \(account) (\(account.uppercased())), shown as \(persona)
        steam ids \(steamID) and 76561198099999999
        mail someone@example.com
        config \(home)/Library/Application Support/Steam/userdata/\(accountID)/config/localconfig.vdf
        """
        let clean = Redactor(paths: paths).clean(text)
        XCTAssertEqual(leaks(clean, paths), [], clean)
        XCTAssertTrue(clean.contains("prefix at ~/Library/Application Support/WovenGames/prefixes/x"), clean)
        XCTAssertTrue(clean.contains("<steam account>"), clean)
        XCTAssertTrue(clean.contains("<steam name>"), clean)
        XCTAssertTrue(clean.contains("steam ids <steamid> and <steamid>"), clean)
        XCTAssertTrue(clean.contains("<email>"), clean)
        XCTAssertTrue(clean.contains("userdata/<steam account id>/config"), clean)
    }

    func testWriteProducesARedactedFolderAndZip() throws {
        let paths = try makeHome()
        let home = paths.home.path(percentEncoded: false)
        let secrets = "home \(home)/x account \(account) id \(steamID) other 76561198099999999 mail someone@example.com dir userdata/\(accountID)\n"
        try put("app started\n" + secrets, paths.logs.appending(path: "app.log"))
        try put("2026-10-10 18:07:10 [wovengames] info np_init: loaded into steam_osx (pid 100) version 1.0.3\n" + secrets, paths.hookLog)
        try put("WOVEN_RETINA=1\n# \(home)\n", paths.support.appending(path: "global.env"))
        try put("CX_GRAPHICS_BACKEND=dxmt\n", paths.support.appending(path: "games/1874000.env"))
        let steamapps = paths.steam.userData.appending(path: "steamapps")
        try put("x", steamapps.appending(path: "common/Double Exposure/game.exe"))
        try put("""
        "AppState"
        {
        \t"appid"\t\t"1874000"
        \t"name"\t\t"Life is Strange: Double Exposure"
        \t"installdir"\t\t"Double Exposure"
        }
        """, steamapps.appending(path: "appmanifest_1874000.acf"))
        try put("=== wovengames run Sat Oct 10 18:00:00 CEST 2026 ===\n" + secrets, steamapps.appending(path: "compatdata/1874000/wovengames-run.log"))
        try put("wine says hi\n" + secrets, paths.support.appending(path: "launchers/1874000/wovengames-wine.log"))

        let out = try makeTempDir("wvo")
        let report = ProblemReport(paths: paths, appVersion: "0.2.0", description: "it broke for \(account) in \(home)")
        let result = try report.write(to: out)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: result.zip.path(percentEncoded: false)))
        let folder = result.folder
        var files: [String] = []
        let walker = try XCTUnwrap(fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let base = folder.resolvingSymlinksInPath().path(percentEncoded: false)
            let full = url.resolvingSymlinksInPath().path(percentEncoded: false)
            XCTAssertTrue(full.hasPrefix(base), full)
            files.append(String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(leaks(text, paths), [], "\(url.lastPathComponent): \(text)")
        }
        XCTAssertEqual(Set(files), ["summary.txt", "logs/app.log", "logs/steam-hook.log", "settings/global.env",
                                    "games/1874000 Life is Strange Double Exposure/about.txt",
                                    "games/1874000 Life is Strange Double Exposure/launch.log",
                                    "games/1874000 Life is Strange Double Exposure/wine.log"])
        let about = try String(contentsOf: folder.appending(path: "games/1874000 Life is Strange Double Exposure/about.txt"), encoding: .utf8)
        XCTAssertTrue(about.contains("Steam launch options: %command% -dx11 CX_GRAPHICS_BACKEND=dxmt"), about)
        XCTAssertTrue(about.contains("CX_GRAPHICS_BACKEND=dxmt"), about)
        let summary = try String(contentsOf: folder.appending(path: "summary.txt"), encoding: .utf8)
        XCTAssertTrue(summary.contains("app: 0.2.0"), summary)
        XCTAssertTrue(summary.contains("it broke for <steam account> in ~"), summary)

        // the zip holds the same folder
        let listing = Shell.capture("/usr/bin/zipinfo", ["-1", result.zip.path(percentEncoded: false)])
        XCTAssertEqual(listing.status, 0, listing.output)
        XCTAssertTrue(listing.output.contains("\(folder.lastPathComponent)/summary.txt"), listing.output)
        XCTAssertTrue(listing.output.contains("\(folder.lastPathComponent)/logs/app.log"), listing.output)
    }

    /// The run log's Steam environment names the account even when loginusers.vdf does not
    /// (another account, a missing or unreadable file).
    func testSteamUserLinesAreRedactedWithoutLoginUsers() throws {
        let home = try makeTempDir("wvr")
        let paths = Paths(home: home, steamApp: home.appending(path: "Steam.app"))
        let clean = Redactor(paths: paths).clean("SteamAppUser=secretlogin\nSteamUser=Secret_Login2\nSteamAppId=1874000\n")
        XCTAssertFalse(clean.lowercased().contains("secret"), clean)
        XCTAssertTrue(clean.contains("SteamAppUser=<steam account>\nSteamUser=<steam account>\nSteamAppId=1874000"), clean)
    }

    /// Only the report's own files go into the zip: no AppleDouble ("._") entries carrying the
    /// files' extended attributes.
    func testZipHoldsNoAppleDoubleFiles() throws {
        let paths = try makeHome()
        try put("app started\n", paths.logs.appending(path: "app.log"))
        // what macOS adds to files apps write (TextEncoding comes from String.write)
        Shell.capture("/usr/bin/xattr", ["-w", "com.example.test", "1", paths.logs.appending(path: "app.log").path(percentEncoded: false)])
        let result = try ProblemReport(paths: paths, appVersion: "0.2.0").write(to: try makeTempDir("wvo"))
        let listing = Shell.capture("/usr/bin/zipinfo", ["-1", result.zip.path(percentEncoded: false)])
        XCTAssertEqual(listing.status, 0, listing.output)
        XCTAssertTrue(listing.output.contains("logs/app.log"), listing.output)
        XCTAssertFalse(listing.output.contains("._"), listing.output)
    }
}

// MARK: - Steam update

final class SteamUpdateTests: XCTestCase {
    var paths: Paths!
    let manifestName = "steam_client_osx.manifest"

    override func setUpWithError() throws {
        let home = try makeTempDir("wvs")
        paths = Paths(home: home, steamApp: home.appending(path: "Applications/Steam.app"))
        try writePlist(insert: home.appending(path: "Applications/Steam.app/Contents/MacOS/wovengames.dylib").path(percentEncoded: false))
        try installBuild("100", at: Date(timeIntervalSinceNow: -86400))
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try SteamPatcher(paths: paths).pin()
        XCTAssertEqual(SteamStatus(paths: paths.steam).pin, .onLaunchOnly)
    }

    func writePlist(insert: String?) throws {
        var env: [String: Any] = ["LC_ALL": "en_US.UTF-8"]
        env["DYLD_INSERT_LIBRARIES"] = insert
        let plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "LSEnvironment": env]
        let url = paths.steam.infoPlist
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    /// What Steam's bootstrapper leaves behind after installing a client build.
    func installBuild(_ build: String, at date: Date) throws {
        try put("\"osx\"\n{\n\t\"version\"\t\t\"\(build)\"\n\t\"pkgs\" { }\n}\n", paths.steam.packageDir.appending(path: manifestName), modified: date)
    }

    static func hookLog(at date: Date, signatures: String = "15/15", hooks: String = "8/8") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let t = f.string(from: date)
        return """
        \(t) [wovengames] info np_init: loaded into steam_osx (pid 4242) version 1.0.3
        \(t) [wovengames] info install_thread: signatures \(signatures) resolved
        \(t) [wovengames] info hooks: \(hooks) installed

        """
    }

    func report(installed: String? = "100", latest: String? = "200") -> SteamBuildReport {
        SteamBuildReport(installed: installed, pending: nil, latestPublic: latest, session: nil, sessionOnInstalled: false,
                         checked: CheckedBuilds(builds: [
                            CheckedBuild(build: 200, channel: "public", resolved: 15, unresolved: 0, checked: "2026-10-01"),
                            CheckedBuild(build: 150, channel: "public", resolved: 13, unresolved: 2, checked: "2026-09-01"),
                         ]))
    }

    func updater(installTimeout: TimeInterval = 10, hookTimeout: TimeInterval = 10) -> SteamUpdater {
        var u = SteamUpdater(paths: paths)
        u.manageSteamProcess = false
        u.pollInterval = 0.02
        u.installTimeout = installTimeout
        u.hookTimeout = hookTimeout
        return u
    }

    func expectError(_ expected: SteamUpdateError, _ body: () throws -> Void, line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line) { XCTAssertEqual($0 as? SteamUpdateError, expected, line: line) }
    }

    func assertPinned(line: UInt = #line) throws {
        XCTAssertEqual(SteamStatus(paths: paths.steam).pin, .onLaunchOnly, line: line)
        XCTAssertTrue(try String(contentsOf: paths.steam.configFile, encoding: .utf8)
            .contains("BootStrapperInhibitUpdateOnLaunch=enable"), line: line)
    }

    func testPreflight() throws {
        let u = updater()
        XCTAssertEqual(try u.preflight(report()), "200")
        expectError(.unknownLatest) { _ = try u.preflight(report(latest: nil)) }
        expectError(.alreadyCurrent("200")) { _ = try u.preflight(report(installed: "200")) }
        expectError(.notChecked("300", "not checked yet")) { _ = try u.preflight(report(latest: "300")) }
        expectError(.notChecked("150", "not supported (2 signatures missing)")) { _ = try u.preflight(report(latest: "150")) }

        try writePlist(insert: nil)
        expectError(.notPatched) { _ = try u.preflight(report()) }
        try writePlist(insert: "/x/notproton.dylib")
        expectError(.notPatched) { _ = try u.preflight(report()) }

        var missing = u
        missing.paths.steamApp = paths.home.appending(path: "Nope/Steam.app")
        expectError(.steamMissing) { _ = try missing.preflight(report()) }
    }

    /// Plays Steam: once the pin is lifted, installs `build` and the hook logs a session.
    func simulateSteam(installing build: String, signatures: String = "15/15") -> Task<Void, Never> {
        let paths = paths!, manifest = paths.steam.packageDir.appending(path: manifestName)
        return Task.detached {
            let deadline = Date().addingTimeInterval(10)
            while SteamStatus(paths: paths.steam).pin != .none && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            // a quick restart: the build lands and the hook logs within the same second
            let second = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            try? "\"osx\"\n{\n\t\"version\"\t\t\"\(build)\"\n}\n".write(to: manifest, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: second.addingTimeInterval(0.3)],
                                                   ofItemAtPath: manifest.path(percentEncoded: false))
            try? await Task.sleep(for: .milliseconds(50))
            let log = SteamUpdateTests.hookLog(at: second, signatures: signatures)
            if let handle = try? FileHandle(forWritingTo: paths.hookLog) {
                handle.seekToEndOfFile()
                handle.write(Data(log.utf8))
                try? handle.close()
            } else {
                try? log.write(to: paths.hookLog, atomically: true, encoding: .utf8)
            }
        }
    }

    func testUpdateInstallsVerifiesAndPinsAgain() async throws {
        // an older session on the old build is in the log already
        try put(Self.hookLog(at: Date(timeIntervalSinceNow: -3600)), paths.hookLog)
        let steam = simulateSteam(installing: "200")
        let log = LogLines()
        try await updater().update(report(), log: { log.add($0) })
        await steam.value
        XCTAssertEqual(SteamStatus(paths: paths.steam).clientBuild, "200")
        try assertPinned()
        XCTAssertTrue(log.all.contains { $0.contains("pinned to it again") }, "\(log.all)")
    }

    func testUpdateTimesOutAndPinsAgain() async throws {
        do {
            try await updater(installTimeout: 0.3).update(report())
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SteamUpdateError, .timedOut(installed: "100", target: "200"))
        }
        try assertPinned()
    }

    func testFailedUnpinPinsAgain() async throws {
        // the client's own steam.cfg cannot be changed: unpin removes the outer pin, then fails
        let inner = paths.steam.innerClient
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inner.path(percentEncoded: false))
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path(percentEncoded: false)) }
        do {
            try await updater().update(report())
            XCTFail("expected the unpin to fail")
        } catch {
            XCTAssertNil(error as? SteamUpdateError, "\(error)")
        }
        try assertPinned()
    }

    func testBrokenHookAfterUpdatePinsAgain() async throws {
        let steam = simulateSteam(installing: "200", signatures: "14/15")
        do {
            try await updater(hookTimeout: 0.5).update(report())
            XCTFail("expected hookBroken")
        } catch {
            XCTAssertEqual(error as? SteamUpdateError, .hookBroken("signatures 14/15"))
        }
        await steam.value
        try assertPinned()
    }
}
