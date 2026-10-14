import SwiftUI
import WovenCore

@main
struct WovenGamesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppModel.Setting.showMenuBar) private var showMenuBar = true

    /// owned by the app delegate, which needs it for Dock clicks
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("WovenGames", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    await model.refresh()
                    // -WovenShowSetup YES opens it regardless (screenshots, support)
                    if !model.isReady || model.hookOutdated || UserDefaults.standard.bool(forKey: "WovenShowSetup") {
                        model.showSetup = true
                    }
                }
                .sheet(isPresented: Binding(get: { model.showSetup }, set: { model.showSetup = $0 })) {
                    SetupAssistant().environment(model)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(before: .appTermination) {
                Button("Uninstall WovenGames…") {
                    model.promptUninstall()
                }
                Divider()
            }
            CommandGroup(after: .windowArrangement) {
                Button("Setup Assistant…") { model.showSetup = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
            HelpCommands()
        }

        Window("Report a Problem", id: "report") {
            ReportProblemView()
                .environment(model)
                .onAppear { AppDelegate.showInDock() }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
                .onAppear { AppDelegate.showInDock() }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Help → WovenGames Help (the README) and Report a Problem…
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("WovenGames Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/BabyJoda420/WovenGames#readme")!)
            }
            Button("Report a Problem…") {
                AppDelegate.showInDock()
                openWindow(id: "report")
                NSApp.activate()
            }
        }
    }
}

enum SidebarItem: String, Hashable, CaseIterable {
    case status = "Status"
    case games = "Games"

    var symbol: String {
        switch self {
        case .status: "checkmark.shield"
        case .games: "gamecontroller"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("section") private var savedSection = SidebarItem.status.rawValue

    private var section: Binding<SidebarItem?> {
        Binding(get: { SidebarItem(rawValue: savedSection) ?? .status },
                set: { savedSection = ($0 ?? .status).rawValue })
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, id: \.self, selection: section) { item in
                Label(item.rawValue, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch section.wrappedValue ?? .status {
            case .status: StatusView()
            case .games: GamesView()
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy != nil)
            }
        }
        .onAppear { AppDelegate.showInDock() }
        .task {
            // lets a notification or the menu bar reopen this window after it was closed
            model.setMainWindowOpener(openWindow)
        }
    }
}
