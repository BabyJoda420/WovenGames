// Snapshots of a Steam game's Wine prefix: <compatdata>/<appid>/woven-snapshots/<id>/pfx
//
// A snapshot is an APFS clone (clonefile), so it is instant and only takes space as the prefix
// changes afterwards. It sits next to the prefix because a clone must stay on the same volume,
// and it goes away with the game's compatdata. Engine updates take one of every WovenGames
// prefix first; those are clones only (never a slow copy) and only the newest few are kept.

import Darwin
import Foundation

public struct PrefixSnapshot: Equatable, Sendable, Identifiable {
    /// "20261014-153000-manual": when, then why
    public var id: String
    public var root: URL
    public var date: Date?
    public var reason: String
    public var prefix: URL { root.appending(path: "pfx") }
    /// "engine-update", or "engine-update2" for a second one in the same second
    public var automatic: Bool { reason.hasPrefix(PrefixSnapshots.engineUpdate) }
}

public enum SnapshotError: Error, CustomStringConvertible {
    case noPrefix(URL)
    case unknown(String)
    case cloneUnsupported
    case gameRunning

    public var description: String {
        switch self {
        case .noPrefix(let url): "no prefix at \(url.path(percentEncoded: false))"
        case .unknown(let id): "no snapshot named \(id)"
        case .cloneUnsupported: "this disk cannot clone (not APFS)"
        case .gameRunning: "the game is running; quit it first"
        }
    }
}

public struct PrefixSnapshots: Sendable {
    public static let engineUpdate = "engine-update"
    public static let manual = "manual"
    /// automatic snapshots kept per game
    public static let keepAutomatic = 3

    /// <compatdata>/<appid>
    public var compatData: URL
    public var prefix: URL { compatData.appending(path: "pfx") }
    public var folder: URL { compatData.appending(path: "woven-snapshots") }

    public init(compatData: URL) { self.compatData = compatData }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Newest first.
    public func list() -> [PrefixSnapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).compactMap { name in
            let root = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: root.appending(path: "pfx").path(percentEncoded: false)) else { return nil }
            let parts = name.split(separator: "-", maxSplits: 2).map(String.init)
            let date = parts.count >= 2 ? Self.stamp.date(from: "\(parts[0])-\(parts[1])") : nil
            return PrefixSnapshot(id: name, root: root, date: date, reason: parts.count == 3 ? parts[2] : "")
        }
    }

    /// Clones the prefix; `allowCopy` falls back to a full copy where cloning is not possible.
    @discardableResult
    public func take(reason: String = PrefixSnapshots.manual, allowCopy: Bool = true, now: Date = Date()) throws -> PrefixSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: prefix.path(percentEncoded: false)) else { throw SnapshotError.noPrefix(prefix) }
        var id = "\(Self.stamp.string(from: now))-\(reason)"
        // two in the same second
        var n = 2
        while fm.fileExists(atPath: folder.appending(path: id).path(percentEncoded: false)) {
            id = "\(Self.stamp.string(from: now))-\(reason)\(n)"
            n += 1
        }
        let root = folder.appending(path: id)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try Self.clone(prefix, to: root.appending(path: "pfx"), allowCopy: allowCopy)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
        if reason == Self.engineUpdate { prune() }
        return PrefixSnapshot(id: id, root: root, date: now, reason: reason)
    }

    /// Puts a snapshot back. The current prefix goes to the Trash first, so this can be undone too.
    public func restore(_ id: String,
                        discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard let snapshot = list().first(where: { $0.id == id }) else { throw SnapshotError.unknown(id) }
        let fm = FileManager.default
        // clone next to the prefix first (the snapshot itself stays for another restore), so a
        // failed clone leaves the current prefix where it was
        let staged = compatData.appending(path: "pfx.restoring")
        try? fm.removeItem(at: staged)
        try Self.clone(snapshot.prefix, to: staged, allowCopy: true)
        do {
            if fm.fileExists(atPath: prefix.path(percentEncoded: false)) { try discard(prefix) }
            try fm.moveItem(at: staged, to: prefix)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    public func delete(_ id: String) throws {
        guard let snapshot = list().first(where: { $0.id == id }) else { throw SnapshotError.unknown(id) }
        try FileManager.default.removeItem(at: snapshot.root)
    }

    /// Drops all but the newest `keepAutomatic` automatic snapshots; manual ones stay.
    func prune() {
        for old in list().filter(\.automatic).dropFirst(Self.keepAutomatic) {
            try? FileManager.default.removeItem(at: old.root)
        }
    }

    static func clone(_ source: URL, to dest: URL, allowCopy: Bool) throws {
        let src = source.path(percentEncoded: false), dst = dest.path(percentEncoded: false)
        // CLONE_NOFOLLOW: a prefix holds symlinks (dosdevices) that must stay links
        if clonefile(src, dst, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        let err = errno
        guard allowCopy else {
            throw err == ENOTSUP || err == EXDEV ? SnapshotError.cloneUnsupported : POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
    }

    /// Before an engine update: a clone of every prefix WovenGames has run (those with
    /// wovengames-run.log). Problems are logged, never thrown: they must not stop the update.
    public static func beforeEngineUpdate(paths: Paths, log: (String) -> Void = { _ in }) {
        let fm = FileManager.default
        for library in SteamLibrary(paths: paths).folders() {
            let compat = library.appending(path: "steamapps/compatdata")
            let ids = (try? fm.contentsOfDirectory(atPath: compat.path(percentEncoded: false))) ?? []
            for id in ids.sorted() {
                let snapshots = PrefixSnapshots(compatData: compat.appending(path: id))
                guard fm.fileExists(atPath: snapshots.compatData.appending(path: "wovengames-run.log").path(percentEncoded: false)),
                      fm.fileExists(atPath: snapshots.prefix.path(percentEncoded: false)) else { continue }
                do {
                    let snapshot = try snapshots.take(reason: engineUpdate, allowCopy: false)
                    log("snapshot of \(id)'s prefix: \(snapshot.id)")
                } catch {
                    log("no snapshot of \(id)'s prefix: \(error)")
                }
            }
        }
    }
}
