// Staying alive in the menu bar after the last window closes, and the Dock icon that goes with it

import AppKit
import WovenCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here (not by the App) so Dock clicks and window events reach it from launch on.
    let model = AppModel()
    private var observers: [NSObjectProtocol] = []
    /// the user chose Quit Anyway while Steam was updating
    private var quitDuringSteamUpdate = false
    private var askingToQuit = false

    /// Read when asked, so a change in Settings applies at once.
    static var keepsRunningInMenuBar: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: AppModel.Setting.showMenuBar)
            && defaults.bool(forKey: AppModel.Setting.keepRunningInMenuBar)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { AppDelegate.windowWillClose(window) }
            },
        ]
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { AppDelegate.windowShown(window) }
            })
        }
        // a window can come up without becoming key or visible on screen (the app in the
        // background, the screen locked); after each pass of the event loop, check once
        observers.append(center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard NSApp.activationPolicy() != .regular,
                      NSApp.windows.contains(where: { $0.isVisible && AppDelegate.isAppWindow($0) }) else { return }
                AppDelegate.showInDock()
            }
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.keepsRunningInMenuBar
    }

    // MARK: quitting during a Steam update

    /// A Steam update lifts the pin until it finishes: quitting first asks, and Quit Anyway
    /// pins Steam again so it stays on whatever build it has now.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.steamUpdateInProgress, !quitDuringSteamUpdate else { return .terminateNow }
        guard !askingToQuit else { return .terminateCancel }
        askingToQuit = true
        DispatchQueue.main.async { [self] in
            let alert = NSAlert()
            alert.messageText = "Steam is updating. Quit anyway?"
            alert.informativeText = "Steam stays on its current build."
            // the safe choice is the default (Return)
            alert.addButton(withTitle: "Keep Updating")
            alert.addButton(withTitle: "Quit Anyway")
            let quit = alert.runModal() == .alertSecondButtonReturn
            askingToQuit = false
            guard quit else { return }
            try? SteamPatcher(paths: model.paths).pin()
            quitDuringSteamUpdate = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // whatever way the quit came, Steam must not stay unpinned
        if model.steamUpdateInProgress { try? SteamPatcher(paths: model.paths).pin() }
    }

    /// A Dock click (or opening the app again in Finder) brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showMainWindow()
        return false
    }

    // MARK: activation policy

    /// The main, Report a Problem and Settings windows; not sheets, panels or the menu bar item.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.sheetParent == nil
    }

    /// The last WovenGames window is closing and the app stays in the menu bar: drop the Dock icon.
    private static func windowWillClose(_ window: NSWindow?) {
        guard let window, isAppWindow(window), keepsRunningInMenuBar else { return }
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && isAppWindow($0) }
        guard others.isEmpty, NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// A WovenGames window came up while the app was menu-bar-only: bring the Dock icon back
    /// and the app forward, so the window is not left behind other apps.
    private static func windowShown(_ window: NSWindow?) {
        guard let window, isAppWindow(window), window.isVisible else { return }
        showInDock()
    }

    /// Back to a regular app with a Dock icon, in front. Called where code opens a window (the
    /// main window opener, Report a Problem) and as each window's root view appears; the window
    /// notifications above catch the rest.
    static func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
