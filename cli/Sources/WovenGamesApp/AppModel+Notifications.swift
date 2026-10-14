// User notifications (a launch that failed, a new release) and bringing the window forward

import AppKit
import Foundation
import UserNotifications

/// Receives notification clicks; UNUserNotificationCenter wants an NSObject delegate.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let onOpen: @MainActor @Sendable (_ appID: String?) -> Void

    init(onOpen: @escaping @MainActor @Sendable (_ appID: String?) -> Void) {
        self.onOpen = onOpen
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let appID = response.notification.request.content.userInfo["appID"] as? String
        let onOpen = onOpen
        Task { @MainActor in onOpen(appID) }
        completionHandler()
    }

    /// shown even while WovenGames is in front
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

extension AppModel {
    /// UNUserNotificationCenter crashes in a process without a bundle (swift run).
    nonisolated static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    /// The delegate goes in before launch finishes, so a click that launched the app is seen too.
    func setUpNotifications() {
        guard Self.canNotify else { return }
        let router = NotificationRouter { [weak self] appID in self?.openFromNotification(appID: appID) }
        notificationRouter = router
        UNUserNotificationCenter.current().delegate = router
    }

    /// Posts a notification, asking for permission the first time one is needed.
    /// `appID` makes a click open that game on the Games page.
    func postNotification(id: String, title: String, body: String, appID: String? = nil) {
        guard Self.canNotify else {
            appLog("notification skipped (no app bundle): \(title)")
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    appLog("notifications are turned off for WovenGames: \(title)")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                if let appID { content.userInfo = ["appID": appID] }
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                appLog("notification failed: \(error)")
            }
        }
    }

    /// A notification was clicked: show the window, on the game it is about.
    func openFromNotification(appID: String?) {
        if let appID {
            requestedGame = appID
            // ContentView's @AppStorage("section") follows this
            UserDefaults.standard.set(SidebarItem.games.rawValue, forKey: "section")
        }
        showMainWindow()
    }

    /// Brings WovenGames forward with its main window open.
    func showMainWindow() {
        NSApp.activate()
        if let openMainWindow {
            openMainWindow()
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
                    ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
