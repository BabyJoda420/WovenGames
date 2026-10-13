// App settings, the login item, the FPS overlay for every game, and problem reports

import AppKit
import Foundation
import ServiceManagement
import WovenCore

extension AppModel {
    /// UserDefaults keys (for @AppStorage too); defaults are registered when the model starts.
    enum Setting {
        static let showMenuBar = "showMenuBar"
        static let keepRunningInMenuBar = "keepRunningInMenuBar"
        static let notifyLaunchProblems = "notifyLaunchProblems"
        static let checkForUpdates = "checkForUpdates"
        static let includeBetas = "includeBetas"
        /// the release tag a notification was last posted for
        static let notifiedUpdateVersion = "notifiedUpdateVersion"

        static let defaults: [String: Any] = [
            showMenuBar: true,
            keepRunningInMenuBar: true,
            notifyLaunchProblems: true,
            checkForUpdates: true,
            includeBetas: false,
        ]
    }

    // MARK: login item

    /// WovenGames opens when the user logs in. Failures go to `error`.
    var openAtLogin: Bool {
        get {
            access(keyPath: \.openAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.openAtLogin) {
                let service = SMAppService.mainApp
                do {
                    if newValue {
                        try service.register()
                        if service.status == .requiresApproval {
                            error = "Allow WovenGames in System Settings → General → Login Items to open it at login."
                        }
                    } else if service.status != .notRegistered {
                        try service.unregister()
                    }
                    appLog("open at login: \(newValue)")
                } catch {
                    self.error = "Could not \(newValue ? "add WovenGames to" : "remove WovenGames from") the login items: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: FPS overlay

    /// Metal's performance HUD in every game (global.env). A game's own setting and its launch
    /// options in Steam still win. Saved off the main thread; failures go to `error`.
    var fpsOverlay: Bool {
        get { fpsOverlayValue }
        set {
            fpsOverlayValue = newValue
            let paths = paths
            let previous = fpsOverlayWrite
            // chained, so quick toggles land in order
            fpsOverlayWrite = Task.detached { [self] in
                await previous?.value
                do {
                    try GlobalSettings(paths: paths).setFPSOverlay(newValue)
                } catch {
                    let actual = GlobalSettings(paths: paths).fpsOverlay
                    await MainActor.run {
                        fpsOverlayValue = actual
                        self.error = "Could not save the FPS overlay setting: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: problem reports

    /// Writes a redacted report folder and zip to the Desktop. Failures go to `error`.
    func writeProblemReport(description: String) async -> ProblemReport.Output? {
        let report = ProblemReport(paths: paths, appVersion: appVersion, description: description)
        let desktop = paths.home.appending(path: "Desktop")
        do {
            let output = try await Task.detached { try report.write(to: desktop) }.value
            appLog("problem report written: \(output.zip.lastPathComponent)")
            return output
        } catch {
            self.error = "Could not write the problem report: \(error)"
            return nil
        }
    }

    /// A new GitHub issue, prefilled with nothing personal: versions only. The report zip
    /// (already redacted) is attached by the user.
    var newIssueURL: URL {
        var components = URLComponents(string: "https://github.com/\(ReleaseInstaller.repository)/issues/new")!
        let body = """
            WovenGames \(appVersion)
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

            Attach the report zip from your Desktop.
            """
        components.queryItems = [
            URLQueryItem(name: "title", value: "Problem report (WovenGames \(appVersion))"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }
}
