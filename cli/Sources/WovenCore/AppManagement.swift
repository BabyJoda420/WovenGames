// macOS "App Management" permission (Privacy & Security): an app needs it to modify another
// app's bundle, here /Applications/Steam.app. There is no API that reports it, so `probe`
// creates and removes an empty file inside Steam.app: macOS answers EPERM when the permission
// is missing. That refusal also lists the calling app under Privacy & Security > App
// Management, so the user finds a switch to turn on.

import Darwin
import Foundation

public enum AppManagementAccess: Equatable, Sendable {
    case granted
    /// macOS refused (EPERM): App Management is off for this app
    case denied
    /// the file system refused (EACCES etc.): e.g. Steam.app belongs to another user
    case notWritable(String)
    case steamMissing

    public var allowed: Bool { self == .granted }
}

public enum AppManagement {
    /// Privacy & Security > App Management
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!
    /// older System Settings
    public static let legacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    public static func probe(steamApp: URL = Paths().steamApp) -> AppManagementAccess {
        let contents = steamApp.appending(path: "Contents")
        guard FileManager.default.fileExists(atPath: contents.path(percentEncoded: false)) else { return .steamMissing }
        let probe = contents.appending(path: ".wovengames-access-probe").path(percentEncoded: false)
        let fd = open(probe, O_CREAT | O_WRONLY | O_EXCL, 0o644)
        if fd >= 0 {
            close(fd)
            unlink(probe)
            return .granted
        }
        let err = errno
        if err == EEXIST {
            // left over from an interrupted probe: removing it is the same test
            return unlink(probe) == 0 ? .granted : (errno == EPERM ? .denied : .notWritable(String(cString: strerror(errno))))
        }
        return err == EPERM ? .denied : .notWritable(String(cString: strerror(err)))
    }

    /// True when an error from writing into Steam.app is macOS refusing App Management.
    public static func isDenial(_ error: Error) -> Bool {
        var current: Error? = error
        while let e = current as NSError? {
            if e.domain == NSPOSIXErrorDomain && e.code == Int(EPERM) { return true }
            if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteNoPermissionError,
               (e.userInfo[NSUnderlyingErrorKey] as? NSError).map({ $0.domain == NSPOSIXErrorDomain && $0.code == Int(EPERM) }) ?? true {
                return true
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }
}
