// Where WovenGames and Steam keep things on disk

import Foundation

public struct Paths: Sendable {
    public var home: URL

    public init(home: URL = URL(filePath: NSHomeDirectory())) {
        self.home = home
    }

    public var applicationSupport: URL { home.appending(path: "Library/Application Support") }

    // ~/Library/Application Support/WovenGames
    public var support: URL { applicationSupport.appending(path: "WovenGames") }
    public var runners: URL { support.appending(path: "runners") }
    public var currentRunner: URL { runners.appending(path: "current") }
    public var prefixes: URL { support.appending(path: "prefixes") }
    public var logs: URL { support.appending(path: "logs") }

    public func prefix(named name: String) -> URL { prefixes.appending(path: name) }

    // Engine build output (engine/scripts/build-all.sh)
    public var engineDist: URL { home.appending(path: "Library/Caches/WovenGames/engine/dist/runners") }

    // NotProton's own install, which M3 takes over
    public var notProtonSupport: URL { applicationSupport.appending(path: "notproton") }

    public var steam: SteamPaths { SteamPaths(home: home) }
}

public struct SteamPaths: Sendable {
    public var home: URL
    public var app = URL(filePath: "/Applications/Steam.app")

    public var infoPlist: URL { app.appending(path: "Contents/Info.plist") }
    public var userData: URL { home.appending(path: "Library/Application Support/Steam") }
    public var configFile: URL { userData.appending(path: "steam.cfg") }
    public var innerClient: URL { userData.appending(path: "Steam.AppBundle/Steam/Contents/MacOS") }
    public var packageDir: URL { innerClient.appending(path: "package") }
    public var compatTools: URL { userData.appending(path: "compatibilitytools.d") }
}
