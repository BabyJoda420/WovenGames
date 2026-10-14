import AppKit
import Foundation
import WovenCore

extension AppModel {
    /// Prompts the user with a confirmation alert to uninstall WovenGames.
    func promptUninstall() {
        if !runningGames.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cannot Uninstall While Games Are Running"
            alert.informativeText = "Please quit all running games (\(runningGames.joined(separator: ", "))) before uninstalling WovenGames."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Uninstall WovenGames?"
        alert.informativeText = "This will restore Steam's original configuration, unpin Steam updates, and remove WovenGames engine files, settings, and logs."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        let checkbox = NSButton(checkboxWithTitle: "Also delete game prefixes (saves)", target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let deletePrefixes = (checkbox.state == .on)
        performUninstall(deletePrefixes: deletePrefixes)
    }

    private func performUninstall(deletePrefixes: Bool) {
        let paths = self.paths
        busy = "Uninstalling WovenGames…"
        Task.detached {
            let uninstaller = Uninstaller(paths: paths, deletePrefixes: deletePrefixes)
            do {
                try uninstaller.run()
                await MainActor.run {
                    // a login item would reopen an app whose files are gone
                    if self.openAtLogin { self.openAtLogin = false }
                    self.busy = nil
                    let done = NSAlert()
                    done.messageText = "WovenGames Uninstalled"
                    done.informativeText = "Steam has been restored and WovenGames runtime files have been removed.\n\nPlease move WovenGames.app to the Trash and quit."
                    done.addButton(withTitle: "Quit")
                    done.runModal()
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.busy = nil
                    let fail = NSAlert()
                    fail.messageText = "Uninstall Failed"
                    fail.informativeText = "\(error)"
                    fail.alertStyle = .critical
                    fail.addButton(withTitle: "OK")
                    fail.runModal()
                }
            }
        }
    }
}
