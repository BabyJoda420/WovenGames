import SwiftUI
import WovenCore

/// The menu bar item's icon: a filled controller while a game runs.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.runningGames.isEmpty ? "gamecontroller" : "gamecontroller.fill")
            .onAppear {
                // the label exists from launch, so a notification can reopen the main window
                // even when it was never shown
                if model.openMainWindow == nil {
                    model.setMainWindowOpener(openWindow)
                }
            }
    }
}

/// The menu bar menu: games playing now, games to start, and the app's windows.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let running = model.menuBarRunningGames
        let recent = model.menuBarRecentGames()

        Group {
            ForEach(running) { game in
                Text(model.menuBarPlayingTitle(game))
                Button("Force Quit \(game.name)") {
                    Task { await model.forceQuit(game) }
                }
                .disabled(model.busy != nil)
            }
            if !running.isEmpty {
                Divider()
            }

            Text("Play")
            if model.games.isEmpty {
                Text("No Windows games installed")
            } else {
                ForEach(recent) { game in
                    Button(game.name) { model.play(game) }
                        .disabled(model.busy != nil)
                }
            }
            Divider()

            Toggle("Show FPS in Games", isOn: $model.fpsOverlay)
                .help("Applies the next time a game starts")

            if let update = model.availableUpdate {
                Button(update.onlyEngine(forApp: model.appVersionValue) ? "Update Engine…" : "Update to \(update.version?.description ?? update.tag_name)…") {
                    UserDefaults.standard.set(SidebarItem.status.rawValue, forKey: "section")
                    model.showMainWindow()
                }
            }

            Divider()
            Button("Open WovenGames") { model.showMainWindow() }
            Button("Report a Problem…") {
                AppDelegate.showInDock()
                openWindow(id: "report")
                NSApp.activate()
            }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit WovenGames") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear {
            model.setMainWindowOpener(openWindow)
        }
    }
}
