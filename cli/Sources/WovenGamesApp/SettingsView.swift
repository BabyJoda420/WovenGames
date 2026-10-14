import SwiftUI

/// The Settings window (WovenGames → Settings…, or the menu bar menu).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            GamesSettings()
                .tabItem { Label("Games", systemImage: "gamecontroller") }
            UpdatesSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.Setting.showMenuBar) private var showMenuBar = true
    @AppStorage(AppModel.Setting.keepRunningInMenuBar) private var keepRunningInMenuBar = true

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Show WovenGames in the menu bar", isOn: $showMenuBar)
            Toggle("Keep running in the menu bar when the window is closed", isOn: $keepRunningInMenuBar)
                .disabled(!showMenuBar)
            Toggle("Open at login", isOn: $model.openAtLogin)
        }
        .formStyle(.grouped)
    }
}

private struct GamesSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.Setting.notifyLaunchProblems) private var notifyLaunchProblems = true

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Tell me when a game fails to start", isOn: $notifyLaunchProblems)
            Toggle(isOn: $model.fpsOverlay) {
                Text("Show FPS in games")
                Text("Apple's Metal performance overlay. Applies the next time a game starts; a game's own setting wins.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdatesSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.Setting.checkForUpdates) private var checkForUpdates = true
    @AppStorage(AppModel.Setting.includeBetas) private var includeBetas = false

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $checkForUpdates)
            Toggle(isOn: $includeBetas) {
                Text("Include beta versions")
                Text("Betas are test builds of the next version.")
            }
            HStack {
                Button("Check Now") { Task { await model.checkForUpdates(manual: true) } }
                    .disabled(model.checkingForUpdates)
                Spacer()
                Text(model.lastUpdateCheck.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
