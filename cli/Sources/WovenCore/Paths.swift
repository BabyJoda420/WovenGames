// Where WovenGames and Steam keep things on disk

import Foundation

public struct Paths: Sendable {
    public var home: URL
    public var steamApp: URL

    /// WOVEN_HOME redirects everything (tests, CI, trying a release without touching a real setup)
    public static var defaultHome: URL {
        ProcessInfo.processInfo.environment["WOVEN_HOME"].map { URL(filePath: $0) } ?? URL(filePath: NSHomeDirectory())
    }

    public init(home: URL = Paths.defaultHome,
                steamApp: URL = URL(filePath: "/Applications/Steam.app")) {
        self.home = home
        self.steamApp = steamApp
    }

    public var applicationSupport: URL { home.appending(path: "Library/Application Support") }

    // ~/Library/Application Support/WovenGames
    public var support: URL { applicationSupport.appending(path: "WovenGames") }
    public var runners: URL { support.appending(path: "runners") }
    public var currentRunner: URL { runners.appending(path: "current") }
    public var prefixes: URL { support.appending(path: "prefixes") }
    public var logs: URL { support.appending(path: "logs") }
    /// what the Steam hook logs (wovengames.dylib inside Steam)
    public var hookLog: URL { support.appending(path: "wovengames.log") }

    public func prefix(named name: String) -> URL { prefixes.appending(path: name) }

    // Engine build tree (engine/scripts/build-all.sh). Not under Caches: macOS empties that
    // when the disk runs low, and a rebuild takes an hour.
    public var engineBuildRoot: URL { home.appending(path: "Library/Developer/WovenGames/engine") }
    public var engineDist: URL { engineBuildRoot.appending(path: "dist/runners") }
    /// which release the installed engine came from ("local build" for `woven setup`)
    public var engineVersionFile: URL { support.appending(path: "engine.version") }

    // NotProton's own install, which M3 takes over
    public var notProtonSupport: URL { applicationSupport.appending(path: "notproton") }

    public var steam: SteamPaths { SteamPaths(home: home, app: steamApp) }
}

public struct SteamPaths: Sendable {
    public var home: URL
    public var app: URL

    public var infoPlist: URL { app.appending(path: "Contents/Info.plist") }
    public var userData: URL { home.appending(path: "Library/Application Support/Steam") }
    public var configFile: URL { userData.appending(path: "steam.cfg") }
    public var innerClient: URL { userData.appending(path: "Steam.AppBundle/Steam/Contents/MacOS") }
    public var packageDir: URL { innerClient.appending(path: "package") }
    public var compatTools: URL { userData.appending(path: "compatibilitytools.d") }
}
