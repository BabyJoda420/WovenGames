// Library artwork Steam has already downloaded (appcache/librarycache/<appid>).
//
// Older clients keep the files directly in the app's folder; newer ones put each kind in a
// hashed subfolder. Either way the file names are the same.

import Foundation

public enum SteamArt: String, Sendable {
    /// portrait capsule, 600x900
    case cover = "library_600x900.jpg"
    /// wide background behind the game's page
    case hero = "library_hero.jpg"
    /// transparent title logo
    case logo = "logo.png"
    case header = "library_header.jpg"

    var fallbacks: [String] {
        switch self {
        case .header: [rawValue, "header.jpg"]
        default: [rawValue]
        }
    }

    public func url(appID: String, paths: Paths = Paths()) -> URL? {
        let folder = paths.steam.userData.appending(path: "appcache/librarycache/\(appID)")
        let fm = FileManager.default
        let dirs = [folder] + ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for name in fallbacks {
            let found = dirs.map { $0.appending(path: name) }.filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
            // several copies after an art update: the newest is what Steam shows
            if let newest = found.max(by: { modified($0) < modified($1) }) { return newest }
        }
        return nil
    }

    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
