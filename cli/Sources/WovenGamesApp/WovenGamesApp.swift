import SwiftUI
import WovenCore

@main
struct WovenGamesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("WovenGames", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .task { await model.refresh() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
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
    }
}
